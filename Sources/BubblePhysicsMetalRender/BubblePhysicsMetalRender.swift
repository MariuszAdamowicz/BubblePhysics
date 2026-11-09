import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsModel
import Metal
import BubblePhysicsNativeMetal
import simd

public enum BubblePhysicsMetalRenderError: Error {
    case deviceMismatch, missingColorTarget, renderEncoderUnavailable
    /// Nie udało się przydzielić bufora pomocniczego klatki (listy instancji, materiałów, wierzchołków i pierścieni).
    case bufferAllocationFailed
}

/// Renderuje opublikowaną klatkę bez materializacji konturów na CPU. Lista rysowania świata (tło, warstwy rosnąco, w nich
/// bańki, potem bryły, każda grupa po `ObjectID`) idzie w jednym passie bez bufora szablonu: sąsiednie obiekty o tym samym
/// trybie mieszania i tej samej teksturze tworzą ciąg rysowany jednym wywołaniem, a kolejność po `ObjectID` zostaje dokładna.
@MainActor
public final class BubblePhysicsMetalRender {
    private let device: MTLDevice
    private let assets: AssetRegistry
    private let pipelines: MaterialPipelines
    /// Biała tekstura 1×1 dla materiałów bez tekstury, bo fragment zawsze próbkuje.
    private let whiteTexture: MTLTexture
    /// Dane zależne tylko od lokalnego pierścienia bryły: indeksy trójkątów i prostokąt otaczający, więc są liczone raz.
    private struct RingGeometry {
        let indices: [Int]
        let minimum: SIMD2<Float>
        let size: SIMD2<Float>
    }
    private var ringGeometryCache: [[WorldPoint]: RingGeometry] = [:]
    private static let ringGeometryCacheLimit = 256
    /// Liczba wywołań rysowania w ostatnio zakodowanej klatce (jedno na ciąg); szew testów grupowania.
    package private(set) var lastDrawCallCount = 0
    /// Zakres bufora pomocniczego klatki jest wyrównany, bo `setVertexBuffer` wymaga wyrównanego przesunięcia.
    private static let arenaAlignment = 256

    /// Rejestr musi należeć do urządzenia renderera, a przy kodowaniu do tego samego świata (`world.assets`).
    public init(device: MTLDevice, assets: AssetRegistry) throws {
        guard assets.deviceRegistryID == device.registryID else { throw AssetError.deviceMismatch }
        self.device = device
        self.assets = assets
        pipelines = try MaterialPipelines(device: device)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        descriptor.usage = .shaderRead
        guard let white = device.makeTexture(descriptor: descriptor) else { throw AssetError.textureCreationFailed }
        white.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: [UInt8](repeating: 255, count: 4), bytesPerRow: 4)
        whiteTexture = white
    }

    /// Ciąg sąsiednich obiektów jednego rodzaju geometrii o tym samym trybie mieszania i teksturze; `first` i `count` dotyczą
    /// bufora instancji baniek albo bufora wierzchołków brył i naklejek.
    private struct Run {
        let geometry: MaterialPipelines.Geometry
        let blend: RenderBlendMode
        let texture: DecalTexture?
        var first: Int
        var count: Int
    }

    /// Dane klatki w kolejności rysowania.
    private struct FrameData {
        var instances: [NativeRenderInstance] = []
        var materials: [NativeRenderMaterial] = []
        var vertices: [NativeRenderBodyVertex] = []
        var rings: [SIMD2<Float>] = []
        var decalInstances: [NativeDecalInstance] = []
        var decalVertices: [NativeDecalVertex] = []
        var runs: [Run] = []
        var materialIndices: [RenderMaterialID: UInt32] = [:]
        /// Ciągi tła (od zera) i ciągi każdej warstwy rosnąco; haki gry wchodzą między te zakresy.
        var backgroundRuns = 0..<0
        var layerRuns: [Int32: Range<Int>] = [:]
        /// Ciągi o indeksie poniżej progu nie przyjmują już kolejnych obiektów, więc zakres segmentu zostaje zamknięty.
        private var mergeFloor = 0

        mutating func beginSegment() { mergeFloor = runs.count }

        mutating func materialIndex(_ id: RenderMaterialID, _ material: RenderMaterial) -> UInt32 {
            if let index = materialIndices[id] { return index }
            let index = UInt32(materials.count)
            materials.append(MaterialPipelines.record(for: material))
            materialIndices[id] = index
            return index
        }

        mutating func extendRun(_ geometry: MaterialPipelines.Geometry, _ material: RenderMaterial, first: Int, count: Int) {
            extendRun(geometry, blend: material.blend, texture: material.texture.map { .texture($0) }, first: first, count: count)
        }

        mutating func extendRun(_ geometry: MaterialPipelines.Geometry, blend: RenderBlendMode, texture: DecalTexture?,
                                first: Int, count: Int) {
            if runs.count > mergeFloor, let last = runs.last, last.geometry == geometry, last.blend == blend,
               last.texture == texture {
                runs[runs.count - 1].count += count
            } else {
                runs.append(Run(geometry: geometry, blend: blend, texture: texture, first: first, count: count))
            }
        }
    }

    /// Rysuje klatkę w jednym passie: tło, warstwy rosnąco, a między nimi haki gry. Haki działają także w świecie bez obiektów
    /// i przed pierwszym krokiem; warstwa z samym hakiem też jest rysowana, w kolejności numerów warstw.
    public func encode(world: BubbleWorld, viewport: Viewport, commandBuffer: MTLCommandBuffer,
                       renderPassDescriptor: MTLRenderPassDescriptor, hooks: RenderHooks = .none) throws {
        guard commandBuffer.device === device, world.assets === assets else { throw BubblePhysicsMetalRenderError.deviceMismatch }
        guard let color = renderPassDescriptor.colorAttachments[0].texture else {
            throw BubblePhysicsMetalRenderError.missingColorTarget
        }
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw BubblePhysicsMetalRenderError.renderEncoderUnavailable
        }
        defer { encoder.endEncoding() }
        encoder.label = "bubble-physics.direct-render"
        lastDrawCallCount = 0
        let published = world.renderState
        let frame = published.map(buildFrame) ?? FrameData()
        let arena = frame.runs.isEmpty ? nil : try makeArena(frame, commandBuffer: commandBuffer)
        var values = SIMD4<Float>(viewport.center.x, viewport.center.y, viewport.size.x, viewport.size.y)
        var boundGeometry: MaterialPipelines.Geometry?
        let matrix = Self.clipMatrix(viewport)

        func draw(_ range: Range<Int>) throws {
            guard let arena else { return }
            for run in frame.runs[range] {
                encoder.setRenderPipelineState(try pipelines.pipeline(run.geometry, blend: run.blend, format: color.pixelFormat))
                // Stager odrzuca transakcje z nieznaną teksturą, więc brak tekstury w rejestrze jest nieosiągalny; biała tekstura
                // jest tylko zabezpieczeniem, które nie ma zepsuć klatki w buildzie bez asercji.
                let registered: MTLTexture?
                switch run.texture {
                case .texture(let id)?: registered = assets.texture(for: id)
                case .atlas(let source)?: registered = assets.atlas(for: source)?.texture
                case nil: registered = nil
                }
                assert(run.texture == nil || registered != nil, "tekstura \(String(describing: run.texture)) nie jest w rejestrze")
                encoder.setFragmentTexture(registered ?? whiteTexture, index: 0)
                switch run.geometry {
                case .bubble:
                    guard let handoff = published?.handoff else { continue }
                    if boundGeometry != .bubble {
                        handoff.bindBubbles(encoder, viewport: viewport, instances: arena.buffer, instanceOffset: arena.instances)
                        encoder.setFragmentBuffer(arena.buffer, offset: arena.materials, index: 0)
                        boundGeometry = .bubble
                    }
                    handoff.drawBubbles(encoder, first: run.first, count: run.count)
                    lastDrawCallCount += 1
                case .body:
                    if boundGeometry != .body {
                        encoder.setVertexBuffer(arena.buffer, offset: arena.vertices, index: 0)
                        encoder.setVertexBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
                        // Rekordy brył z uchwytu niosą pozy t−1 i t; tło ma współrzędne świata i nie czyta rekordów.
                        if let handoff = published?.handoff { handoff.bindBodies(encoder) }
                        else { encoder.setVertexBuffer(arena.buffer, offset: 0, index: 4) }
                        encoder.setFragmentBuffer(arena.buffer, offset: arena.materials, index: 0)
                        encoder.setFragmentBuffer(arena.buffer, offset: arena.rings, index: 1)
                        boundGeometry = .body
                    }
                    encoder.drawPrimitives(type: .triangle, vertexStart: run.first, vertexCount: run.count)
                    lastDrawCallCount += 1
                case .decal:
                    // Kotwica naklejki (bańki i bryły) pochodzi z rekordów uchwytu, więc bez uchwytu nie ma naklejek.
                    guard let handoff = published?.handoff else { continue }
                    if boundGeometry != .decal {
                        handoff.bindDecals(encoder, viewport: viewport, vertices: arena.buffer, vertexOffset: arena.decalVertices,
                                           instances: arena.buffer, instanceOffset: arena.decalInstances)
                        boundGeometry = .decal
                    }
                    encoder.drawPrimitives(type: .triangle, vertexStart: run.first, vertexCount: run.count)
                    lastDrawCallCount += 1
                }
            }
        }

        /// Hak gry zmienia potok i wiązania encodera, więc po nim następny ciąg wiąże arenę i bufory handoffu od nowa.
        func call(_ hook: RenderHooks.Hook?) throws {
            guard let hook else { return }
            try hook(encoder, matrix)
            boundGeometry = nil
        }

        try draw(frame.backgroundRuns)
        try call(hooks.afterBackground)
        for layer in Set(frame.layerRuns.keys).union(hooks.afterLayer.keys).sorted() {
            try draw(frame.layerRuns[layer] ?? 0..<0)
            try call(hooks.afterLayer[layer])
        }
        try call(hooks.overlay)
    }

    /// Macierz świat → clip tej samej kamery co `nativeClip` w shaderach: (punkt − środek) · 2 / rozmiar.
    static func clipMatrix(_ viewport: Viewport) -> simd_float4x4 {
        let scale = SIMD2<Float>(2 / viewport.size.x, 2 / viewport.size.y)
        return simd_float4x4(columns: (SIMD4(scale.x, 0, 0, 0), SIMD4(0, scale.y, 0, 0), SIMD4(0, 0, 1, 0),
                                       SIMD4(-viewport.center.x * scale.x, -viewport.center.y * scale.y, 0, 1)))
    }

    /// Przekłada listę rysowania świata na dane klatki: instancje baniek (indeks rekordu w uchwycie), trójkąty brył z
    /// lokalnymi współrzędnymi i pierścieniami konturu oraz ciągi o wspólnym trybie mieszania i teksturze.
    private func buildFrame(_ state: BubbleWorldRenderState) -> FrameData {
        var frame = FrameData()
        let decals = DecalRenderer(assets: assets)
        if let background = state.background { appendBackground(background, region: state.region, to: &frame) }
        frame.backgroundRuns = 0..<frame.runs.count
        for layer in state.layers {
            let firstRun = frame.runs.count
            frame.beginSegment()
            defer { frame.layerRuns[layer.layer] = firstRun..<frame.runs.count }
            if let handoff = state.handoff {
                for bubble in layer.bubbles {
                    guard let index = handoff.bubbleIndexByID[bubble.id] else { continue }
                    let material = frame.materialIndex(bubble.materialID, bubble.material)
                    frame.extendRun(.bubble, bubble.material, first: frame.instances.count, count: 1)
                    frame.instances.append(NativeRenderInstance(bubble: UInt32(index), material: material,
                        previous: previousIndex(of: bubble.id, state, handoff), alpha: state.interpolation))
                }
                // Naklejki baniek po wszystkich bańkach warstwy; kotwica i promień odniesienia z rekordu bańki w shaderze,
                // interpolowane t−1 → t razem z bańką.
                for bubble in layer.bubbles {
                    guard let decal = bubble.decal, let index = handoff.bubbleIndexByID[bubble.id] else { continue }
                    appendDecal(decal, placement: .zero, bubbleIndex: UInt32(index),
                                previousBubbleIndex: previousIndex(of: bubble.id, state, handoff), alpha: state.interpolation,
                                renderer: decals, to: &frame)
                }
            }
            // Bryły rysuje poza z rekordu GPU: wierzchołki i pierścienie są lokalne, shader nakłada pozę z mieszaniem t−1 → t
            // (bez niego dla obiektów, które pojawiły się w kroku, i dla zawiniętych: wagę 1 daje CPU, a zawinięcie flaga rekordu).
            // Bryła spoza uchwytu nie istnieje w opublikowanym kroku GPU, więc nie ma jeszcze pozy do narysowania.
            if let handoff = state.handoff {
                for shape in layer.shapes {
                    let ring = ringGeometry(for: shape.localVertices)
                    let indices = ring.indices
                    guard !indices.isEmpty, let body = handoff.bodyIndexByID[shape.id] else { continue }
                    let material = frame.materialIndex(shape.materialID, shape.material)
                    let ringStart = UInt32(frame.rings.count), ringCount = UInt32(shape.localVertices.count)
                    frame.rings += shape.localVertices.map { SIMD2($0.x, $0.y) }
                    let info = SIMD4<UInt32>(material, ringStart, ringCount, UInt32(body))
                    let weight = Self.weight(of: shape.id, state)
                    frame.extendRun(.body, shape.material, first: frame.vertices.count, count: indices.count)
                    // Tekstura rozciągnięta na lokalny prostokąt otaczający, wiersz 0 obrazu u góry; obraca się z bryłą.
                    for index in indices {
                        let local = shape.localVertices[index]
                        let uv = SIMD2((local.x - ring.minimum.x) / ring.size.x, 1 - (local.y - ring.minimum.y) / ring.size.y)
                        frame.vertices.append(NativeRenderBodyVertex(local: SIMD2(local.x, local.y), uv: uv, info: info, weight: weight))
                    }
                }
                // Naklejki brył po wszystkich bryłach warstwy; kotwica i obrót z rekordu bryły, jak sama bryła.
                for shape in layer.shapes {
                    guard let decal = shape.decal, let body = handoff.bodyIndexByID[shape.id] else { continue }
                    appendDecal(decal, placement: SIMD4(0, 0, shape.referenceRadius, 0), bubbleIndex: NativeDecalInstance.noBubble,
                                alpha: Self.weight(of: shape.id, state), bodyIndex: UInt32(body), renderer: decals, to: &frame)
                }
            }
        }
        return frame
    }

    /// Indeks rekordu bańki na stronie t−1. Bez ważnej strony t−1 albo dla obiektu, który pojawił się w tym kroku, bańka rysuje
    /// się w stanie t; zawinięcie wykrywa shader po fladze rekordu (znane dopiero po kroku GPU).
    private func previousIndex(of id: ObjectID, _ state: BubbleWorldRenderState, _ handoff: NativeMetalRenderHandoff) -> UInt32 {
        if state.snapped.contains(id) { return NativeRenderInstance.noPrevious }
        return handoff.previousBubbleIndexByID[id].map { UInt32($0) } ?? NativeRenderInstance.noPrevious
    }

    /// Waga stanu t w obrazie obiektu: 1 (bez interpolacji) dla obiektu, który pojawił się w ostatnim kroku.
    private static func weight(of id: ObjectID, _ state: BubbleWorldRenderState) -> Float {
        state.snapped.contains(id) ? 1 : state.interpolation
    }

    private func appendDecal(_ decal: Decal, placement: SIMD4<Float>, bubbleIndex: UInt32,
                             previousBubbleIndex: UInt32 = NativeDecalInstance.noPrevious, alpha: Float = 1, bodyIndex: UInt32 = 0,
                             renderer: DecalRenderer, to frame: inout FrameData) {
        let instanceIndex = UInt32(frame.decalInstances.count)
        guard let layout = renderer.layout(decal, placement: placement, bubbleIndex: bubbleIndex,
                                           previousBubbleIndex: previousBubbleIndex, alpha: alpha, bodyIndex: bodyIndex,
                                           instanceIndex: instanceIndex)
        else { return }
        frame.decalInstances.append(layout.instance)
        frame.extendRun(.decal, blend: .alpha, texture: layout.texture, first: frame.decalVertices.count,
                        count: layout.vertices.count)
        frame.decalVertices += layout.vertices
    }

    /// Tło to czworokąt regionu z teksturą rozciągniętą na cały region, rysowany przed warstwami w trybie nieprzezroczystym.
    private func appendBackground(_ texture: TextureID, region: WorldRectangle, to frame: inout FrameData) {
        guard let material = try? RenderMaterial(texture: texture) else { return }
        let index = UInt32(frame.materials.count)
        frame.materials.append(MaterialPipelines.record(for: material))
        frame.extendRun(.body, material, first: frame.vertices.count, count: 6)
        let info = SIMD4<UInt32>(index, 0, 0, NativeRenderBodyVertex.noBody)
        let (low, high) = (region.min, region.max)
        let corners: [(SIMD2<Float>, SIMD2<Float>)] = [
            (SIMD2(low.x, high.y), SIMD2(0, 0)), (SIMD2(high.x, high.y), SIMD2(1, 0)),
            (SIMD2(high.x, low.y), SIMD2(1, 1)), (SIMD2(low.x, low.y), SIMD2(0, 1))]
        for corner in [0, 1, 2, 0, 2, 3] {
            frame.vertices.append(NativeRenderBodyVertex(local: corners[corner].0, uv: corners[corner].1, info: info))
        }
    }

    private struct Arena {
        let buffer: MTLBuffer
        let instances: Int, materials: Int, vertices: Int, rings: Int, decalInstances: Int, decalVertices: Int
    }

    /// Jeden bufor współdzielony na klatkę z czterema blokami; żyje do końca bufora poleceń.
    private func makeArena(_ frame: FrameData, commandBuffer: MTLCommandBuffer) throws -> Arena {
        func aligned(_ value: Int) -> Int { (value + Self.arenaAlignment - 1) / Self.arenaAlignment * Self.arenaAlignment }
        let instances = 0
        let materials = aligned(instances + frame.instances.count * MemoryLayout<NativeRenderInstance>.stride)
        let vertices = aligned(materials + frame.materials.count * MemoryLayout<NativeRenderMaterial>.stride)
        let rings = aligned(vertices + frame.vertices.count * MemoryLayout<NativeRenderBodyVertex>.stride)
        // Każdy blok musi mieć przesunięcie mniejsze od długości bufora (walidacja Metal), także pusty blok pierścieni
        // (klatka z samym tłem) i bloki naklejek, więc rezerwujemy w nich co najmniej jeden element.
        let decalInstances = aligned(rings + max(frame.rings.count, 1) * MemoryLayout<SIMD2<Float>>.stride)
        let decalVertices = aligned(decalInstances + max(frame.decalInstances.count, 1) * MemoryLayout<NativeDecalInstance>.stride)
        let length = aligned(decalVertices + max(frame.decalVertices.count, 1) * MemoryLayout<NativeDecalVertex>.stride)
        // Bufor jest przydzielany co klatkę (zawartość zależy od klatki i musi przeżyć jej bufor poleceń); pierścień
        // buforów byłby optymalizacją, której ta klatka jeszcze nie wymaga.
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw BubblePhysicsMetalRenderError.bufferAllocationFailed
        }
        func copy<T>(_ values: [T], to offset: Int) {
            values.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                (buffer.contents() + offset).copyMemory(from: base, byteCount: bytes.count)
            }
        }
        copy(frame.instances, to: instances); copy(frame.materials, to: materials)
        copy(frame.vertices, to: vertices); copy(frame.rings, to: rings)
        copy(frame.decalInstances, to: decalInstances); copy(frame.decalVertices, to: decalVertices)
        let retained = RetainedFrameBuffer(buffer)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        return Arena(buffer: buffer, instances: instances, materials: materials, vertices: vertices, rings: rings,
                     decalInstances: decalInstances, decalVertices: decalVertices)
    }

    /// Indeksy trójkątów i prostokąt otaczający zależą tylko od lokalnego pierścienia, więc są używane ponownie między klatkami.
    private func ringGeometry(for ring: [WorldPoint]) -> RingGeometry {
        if let cached = ringGeometryCache[ring] { return cached }
        if ringGeometryCache.count >= Self.ringGeometryCacheLimit { ringGeometryCache.removeAll(keepingCapacity: true) }
        var minimum = SIMD2<Float>(repeating: .infinity), maximum = SIMD2<Float>(repeating: -.infinity)
        for point in ring { minimum = pointwiseMin(minimum, point); maximum = pointwiseMax(maximum, point) }
        if ring.isEmpty { minimum = .zero; maximum = .zero }
        let size = SIMD2(max(maximum.x - minimum.x, 1e-6), max(maximum.y - minimum.y, 1e-6))
        let geometry = RingGeometry(indices: Self.triangulate(ring), minimum: minimum, size: size)
        ringGeometryCache[ring] = geometry
        return geometry
    }

    /// Ear clipping obsługuje także wklęsłe proste pierścienie z modelu.
    static func triangulate(_ ring: [WorldPoint]) -> [Int] {
        guard ring.count >= 3 else { return [] }
        let area = ring.indices.reduce(Float.zero) { sum, i in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return sum + a.x * b.y - b.x * a.y
        }
        let sign: Float = area >= 0 ? 1 : -1
        var indices = Array(ring.indices)
        var output: [Int] = []
        while indices.count > 3 {
            var clipped = false
            for i in indices.indices {
                let previous = indices[(i + indices.count - 1) % indices.count]
                let current = indices[i]
                let next = indices[(i + 1) % indices.count]
                let a = ring[previous], b = ring[current], c = ring[next]
                let cross = (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
                guard cross * sign > 0 else { continue }
                let contains = indices.contains { candidate in
                    guard candidate != previous && candidate != current && candidate != next else { return false }
                    let p = ring[candidate]
                    let ab = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                    let bc = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
                    let ca = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
                    return ab * sign >= 0 && bc * sign >= 0 && ca * sign >= 0
                }
                guard !contains else { continue }
                output += [previous, current, next]
                indices.remove(at: i)
                clipped = true
                break
            }
            if !clipped { return [] }
        }
        output += indices
        return output
    }
}

private struct RetainedFrameBuffer: @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
}
