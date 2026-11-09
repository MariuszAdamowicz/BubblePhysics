import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsModel
import Metal
import BubblePhysicsNativeMetal

public enum BubblePhysicsMetalRenderError: Error {
    case deviceMismatch, missingColorTarget, renderEncoderUnavailable
}

/// Renderuje opublikowaną klatkę bez materializacji konturów na CPU. Lista rysowania świata (tło, warstwy rosnąco, w nich
/// bańki, potem bryły, każda grupa po `ObjectID`) idzie w jednym passie bez bufora szablonu: sąsiednie obiekty o tym samym
/// trybie mieszania i tej samej teksturze tworzą ciąg rysowany jednym wywołaniem, a kolejność po `ObjectID` zostaje dokładna.
@MainActor
public final class BubblePhysicsMetalRender {
    private let device: MTLDevice
    private let assets: AssetRegistry
    private let pipelines: MaterialPipelines
    private var triangulationCache: [[WorldPoint]: [Int]] = [:]
    private static let triangulationCacheLimit = 256
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
    }

    /// Ciąg sąsiednich obiektów jednego rodzaju geometrii o tym samym trybie mieszania i teksturze; `first` i `count` dotyczą
    /// bufora instancji baniek albo bufora wierzchołków brył.
    private struct Run {
        let geometry: MaterialPipelines.Geometry
        let blend: RenderBlendMode
        let texture: TextureID?
        var first: Int
        var count: Int
    }

    /// Dane klatki w kolejności rysowania.
    private struct FrameData {
        var instances: [NativeRenderInstance] = []
        var materials: [NativeRenderMaterial] = []
        var vertices: [NativeRenderBodyVertex] = []
        var rings: [SIMD2<Float>] = []
        var runs: [Run] = []
        var materialIndices: [RenderMaterialID: UInt32] = [:]

        mutating func materialIndex(_ id: RenderMaterialID, _ material: RenderMaterial) -> UInt32 {
            if let index = materialIndices[id] { return index }
            let index = UInt32(materials.count)
            materials.append(MaterialPipelines.record(for: material))
            materialIndices[id] = index
            return index
        }

        mutating func extendRun(_ geometry: MaterialPipelines.Geometry, _ material: RenderMaterial, first: Int, count: Int) {
            if let last = runs.last, last.geometry == geometry, last.blend == material.blend, last.texture == material.texture {
                runs[runs.count - 1].count += count
            } else {
                runs.append(Run(geometry: geometry, blend: material.blend, texture: material.texture, first: first, count: count))
            }
        }
    }

    public func encode(world: BubbleWorld, viewport: Viewport, commandBuffer: MTLCommandBuffer,
                       renderPassDescriptor: MTLRenderPassDescriptor) throws {
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
        guard let published = world.renderState else { return }
        let frame = buildFrame(published)
        guard !frame.runs.isEmpty else { return }
        let arena = try makeArena(frame, commandBuffer: commandBuffer)
        var values = SIMD4<Float>(viewport.center.x, viewport.center.y, viewport.size.x, viewport.size.y)
        var boundGeometry: MaterialPipelines.Geometry?
        for run in frame.runs {
            encoder.setRenderPipelineState(try pipelines.pipeline(run.geometry, blend: run.blend, format: color.pixelFormat))
            switch run.geometry {
            case .bubble:
                guard let handoff = published.handoff else { continue }
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
                    encoder.setFragmentBuffer(arena.buffer, offset: arena.materials, index: 0)
                    encoder.setFragmentBuffer(arena.buffer, offset: arena.rings, index: 1)
                    boundGeometry = .body
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: run.first, vertexCount: run.count)
                lastDrawCallCount += 1
            }
        }
    }

    /// Przekłada listę rysowania świata na dane klatki: instancje baniek (indeks rekordu w uchwycie), trójkąty brył z
    /// lokalnymi współrzędnymi i pierścieniami konturu oraz ciągi o wspólnym trybie mieszania i teksturze.
    private func buildFrame(_ state: BubbleWorldRenderState) -> FrameData {
        var frame = FrameData()
        for layer in state.layers {
            if let handoff = state.handoff {
                for bubble in layer.bubbles {
                    guard let index = handoff.bubbleIndexByID[bubble.id] else { continue }
                    let material = frame.materialIndex(bubble.materialID, bubble.material)
                    frame.extendRun(.bubble, bubble.material, first: frame.instances.count, count: 1)
                    frame.instances.append(NativeRenderInstance(bubble: UInt32(index), material: material))
                }
            }
            for shape in layer.shapes {
                let indices = triangulation(for: shape.localVertices)
                guard !indices.isEmpty else { continue }
                let material = frame.materialIndex(shape.materialID, shape.material)
                let ringStart = UInt32(frame.rings.count), ringCount = UInt32(shape.vertices.count)
                frame.rings += shape.vertices.map { SIMD2($0.x, $0.y) }
                let info = SIMD4<UInt32>(material, ringStart, ringCount, 0)
                frame.extendRun(.body, shape.material, first: frame.vertices.count, count: indices.count)
                for index in indices {
                    let world = shape.vertices[index], local = shape.localVertices[index]
                    frame.vertices.append(NativeRenderBodyVertex(world: SIMD2(world.x, world.y),
                                                                  local: SIMD2(local.x, local.y), info: info))
                }
            }
        }
        return frame
    }

    private struct Arena {
        let buffer: MTLBuffer
        let instances: Int, materials: Int, vertices: Int, rings: Int
    }

    /// Jeden bufor współdzielony na klatkę z czterema blokami; żyje do końca bufora poleceń.
    private func makeArena(_ frame: FrameData, commandBuffer: MTLCommandBuffer) throws -> Arena {
        func aligned(_ value: Int) -> Int { (value + Self.arenaAlignment - 1) / Self.arenaAlignment * Self.arenaAlignment }
        let instances = 0
        let materials = aligned(instances + frame.instances.count * MemoryLayout<NativeRenderInstance>.stride)
        let vertices = aligned(materials + frame.materials.count * MemoryLayout<NativeRenderMaterial>.stride)
        let rings = aligned(vertices + frame.vertices.count * MemoryLayout<NativeRenderBodyVertex>.stride)
        let length = max(aligned(rings + frame.rings.count * MemoryLayout<SIMD2<Float>>.stride), Self.arenaAlignment)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw BubblePhysicsMetalRenderError.renderEncoderUnavailable
        }
        func copy<T>(_ values: [T], to offset: Int) {
            values.withUnsafeBytes { bytes in
                guard let base = bytes.baseAddress else { return }
                (buffer.contents() + offset).copyMemory(from: base, byteCount: bytes.count)
            }
        }
        copy(frame.instances, to: instances); copy(frame.materials, to: materials)
        copy(frame.vertices, to: vertices); copy(frame.rings, to: rings)
        let retained = RetainedShapeBuffer(buffer)
        commandBuffer.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
        return Arena(buffer: buffer, instances: instances, materials: materials, vertices: vertices, rings: rings)
    }

    /// Indeksy trójkątów zależą tylko od lokalnego pierścienia, więc są używane ponownie między klatkami.
    private func triangulation(for ring: [WorldPoint]) -> [Int] {
        if let cached = triangulationCache[ring] { return cached }
        if triangulationCache.count >= Self.triangulationCacheLimit { triangulationCache.removeAll(keepingCapacity: true) }
        let indices = Self.triangulate(ring)
        triangulationCache[ring] = indices
        return indices
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

private struct RetainedShapeBuffer: @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
}
