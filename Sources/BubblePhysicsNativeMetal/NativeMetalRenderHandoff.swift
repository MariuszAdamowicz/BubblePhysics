import Metal
import BubblePhysicsModel

/// Nieprzezroczysty uchwyt do kompletnej, opublikowanej klatki GPU.
/// Bufory pozostają własnością backendu i nie są częścią publicznego API gry.
@MainActor
package final class NativeMetalRenderHandoff {
    private let points: MTLBuffer
    private let counts: MTLBuffer
    private let bubbles: MTLBuffer
    /// Druga strona konturów (krok t−1) w roli ping-pong solvera; `nil` przed pierwszą publikacją. Bez kopii: to ten sam bufor,
    /// który następny krok nadpisze, dlatego `previousContoursValid` gaśnie, gdy krok bez publikacji go zepsuje.
    private let previousPoints: MTLBuffer?
    private let previousCounts: MTLBuffer?
    /// Rekordy baniek strony t−1 (środek poprzedniego kroku); ta sama druga połowa ping-pong co punkty.
    private let previousBubbles: MTLBuffer?
    /// Kolejność baniek na stronie t−1 (indeks rekordu w buforach t−1); pusta, gdy strony t−1 nie ma.
    package let previousBubbleIDs: [ObjectID]
    /// Czy strona t−1 nadal trzyma kontury z poprzedniej publikacji. Fałsz, gdy nie ma strony t−1 albo krok wykonany na GPU
    /// bez publikacji nadpisał ją; wtedy renderer rysuje bez interpolacji.
    package private(set) var previousContoursValid: Bool
    package let bubbleIDs: [ObjectID]
    package var bubbleCount: Int { bubbleIDs.count }
    package let contourStride: Int
    /// Rozmiar jednego rekordu `RenderBubble` w ABI shadera renderu (ten sam układ co `NativeBubble`).
    package static let bubbleRecordByteCount = MemoryLayout<NativeMetalBubble>.stride

    /// Indeks rekordu bańki w uchwycie; budowany raz na uchwyt przy pierwszym użyciu przez renderer.
    package private(set) lazy var bubbleIndexByID: [ObjectID: Int] = Dictionary(
        uniqueKeysWithValues: bubbleIDs.enumerated().map { ($0.element, $0.offset) })

    /// Indeks rekordów stron t−1 budowany raz na uchwyt; słownik nie niesie ważności, bo ta zmienia się w czasie życia uchwytu.
    private lazy var previousIndexByID: [ObjectID: Int] = Dictionary(
        uniqueKeysWithValues: previousBubbleIDs.enumerated().map { ($0.element, $0.offset) })

    /// Indeks rekordu bańki na stronie t−1; pusty, gdy nie ma ważnej strony t−1 (wtedy bańka rysuje się bez interpolacji).
    /// Ważność jest sprawdzana przy każdym odczycie: krok bez publikacji może ją zgasić po pierwszym użyciu uchwytu.
    package var previousBubbleIndexByID: [ObjectID: Int] { previousContoursValid ? previousIndexByID : [:] }

    init(points: MTLBuffer, counts: MTLBuffer, bubbles: MTLBuffer,
         bubbleIDs: [ObjectID], contourStride: Int,
         previousPoints: MTLBuffer? = nil, previousCounts: MTLBuffer? = nil, previousBubbles: MTLBuffer? = nil,
         previousBubbleIDs: [ObjectID] = []) {
        self.points = points
        self.counts = counts
        self.bubbles = bubbles
        self.bubbleIDs = bubbleIDs
        self.contourStride = contourStride
        self.previousPoints = previousPoints
        self.previousCounts = previousCounts
        self.previousBubbles = previousBubbles
        self.previousBubbleIDs = previousBubbleIDs
        previousContoursValid = previousPoints != nil && previousCounts != nil && previousBubbles != nil
    }

    /// Solver wywołuje to, gdy krok wykonany na GPU nie został opublikowany: zapisał stronę t−1 tego uchwytu.
    func invalidatePreviousContours() { previousContoursValid = false }

    private static var compiledFunctions: [UInt64: NativeRenderFunctions] = [:]

    /// Kompiluje shadery renderu raz na urządzenie; kolejne renderery używają tych samych funkcji.
    package static func makeFunctions(device: MTLDevice) throws -> NativeRenderFunctions {
        if let cached = compiledFunctions[device.registryID] { return cached }
        guard let url = Bundle.module.url(forResource: "NativeRenderKernels", withExtension: "metal-source") else {
            throw NativeRenderError.resourceUnavailable
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let bubbleVertex = library.makeFunction(name: "nativeBubbleVertex"),
              let bodyVertex = library.makeFunction(name: "nativeBodyVertex"),
              let bubbleFragment = library.makeFunction(name: "nativeBubbleFragment"),
              let bodyFragment = library.makeFunction(name: "nativeBodyFragment"),
              let decalVertex = library.makeFunction(name: "nativeDecalVertex"),
              let decalFragment = library.makeFunction(name: "nativeDecalFragment") else {
            throw NativeRenderError.resourceUnavailable
        }
        let functions = NativeRenderFunctions(bubbleVertex: bubbleVertex, bodyVertex: bodyVertex,
            bubbleFragment: bubbleFragment, bodyFragment: bodyFragment,
            decalVertex: decalVertex, decalFragment: decalFragment)
        compiledFunctions[device.registryID] = functions
        return functions
    }

    /// Wiąże bufory konturów baniek i bufor instancji (kolejność rysowania); bańki idą potem ciągami przez `drawBubbles`.
    package func bindBubbles(_ encoder: MTLRenderCommandEncoder, viewport: Viewport, instances: MTLBuffer, instanceOffset: Int) {
        encoder.setVertexBuffer(points, offset: 0, index: 0)
        encoder.setVertexBuffer(counts, offset: 0, index: 1)
        encoder.setVertexBuffer(bubbles, offset: 0, index: 4)
        encoder.setVertexBuffer(instances, offset: instanceOffset, index: 7)
        // Strona t−1 (punkty, liczniki, rekordy); bez niej zaślepki, bo instancje i tak nie wskażą indeksu t−1.
        encoder.setVertexBuffer(previousPoints ?? points, offset: 0, index: 5)
        encoder.setVertexBuffer(previousCounts ?? counts, offset: 0, index: 6)
        encoder.setVertexBuffer(previousBubbles ?? bubbles, offset: 0, index: 8)
        var values = SIMD4<Float>(viewport.center.x, viewport.center.y, viewport.size.x, viewport.size.y)
        encoder.setVertexBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        var stride = UInt32(contourStride)
        encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 3)
    }

    /// Jedno wywołanie rysowania na ciąg `count` instancji od `first` w buforze instancji.
    package func drawBubbles(_ encoder: MTLRenderCommandEncoder, first: Int, count: Int) {
        guard count > 0 else { return }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: contourStride * 3,
                               instanceCount: count, baseInstance: first)
    }

    /// Wiąże dane naklejek: wierzchołki i instancje z areny, rekordy baniek t i t−1 (kotwica i promień odniesienia) oraz liczniki
    /// w wierzchołku, a kontury baniek t i t−1 w fragmencie (maska radialna). Bez ważnej strony t−1 wiązane są strony t jako
    /// zaślepki, bo instancje i tak nie wskażą indeksu t−1. Bez uchwytu (świat bez kroku GPU) `bindDecalsWithoutBubbles`.
    package func bindDecals(_ encoder: MTLRenderCommandEncoder, viewport: Viewport, vertices: MTLBuffer, vertexOffset: Int,
                            instances: MTLBuffer, instanceOffset: Int) {
        encoder.setVertexBuffer(bubbles, offset: 0, index: 4)
        encoder.setVertexBuffer(previousBubbles ?? bubbles, offset: 0, index: 5)
        encoder.setVertexBuffer(counts, offset: 0, index: 6)
        encoder.setVertexBuffer(previousCounts ?? counts, offset: 0, index: 7)
        var stride = UInt32(contourStride)
        encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setFragmentBuffer(points, offset: 0, index: 0)
        encoder.setFragmentBuffer(counts, offset: 0, index: 1)
        encoder.setFragmentBuffer(previousPoints ?? points, offset: 0, index: 3)
        Self.bindDecalCommon(encoder, viewport: viewport, vertices: vertices, vertexOffset: vertexOffset,
                             instances: instances, instanceOffset: instanceOffset, stride: contourStride)
    }

    /// Naklejki samych brył: shader deklaruje bufory baniek i konturów, więc dostają zaślepkę (nikt ich nie czyta).
    package static func bindDecalsWithoutBubbles(_ encoder: MTLRenderCommandEncoder, viewport: Viewport, vertices: MTLBuffer,
                                                 vertexOffset: Int, instances: MTLBuffer, instanceOffset: Int) {
        for index in 4...7 { encoder.setVertexBuffer(vertices, offset: 0, index: index) }
        var stride: UInt32 = 0
        encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 3)
        for index in [0, 1, 3] { encoder.setFragmentBuffer(vertices, offset: 0, index: index) }
        bindDecalCommon(encoder, viewport: viewport, vertices: vertices, vertexOffset: vertexOffset,
                        instances: instances, instanceOffset: instanceOffset, stride: 0)
    }

    private static func bindDecalCommon(_ encoder: MTLRenderCommandEncoder, viewport: Viewport, vertices: MTLBuffer,
                                        vertexOffset: Int, instances: MTLBuffer, instanceOffset: Int, stride: Int) {
        encoder.setVertexBuffer(vertices, offset: vertexOffset, index: 0)
        encoder.setVertexBuffer(instances, offset: instanceOffset, index: 1)
        var values = SIMD4<Float>(viewport.center.x, viewport.center.y, viewport.size.x, viewport.size.y)
        encoder.setVertexBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        var contourStride = UInt32(stride)
        encoder.setFragmentBytes(&contourStride, length: MemoryLayout<UInt32>.stride, index: 2)
    }

    /// Wyłącznie adapter diagnostyczny. Produkcyjny renderer nie wywołuje tej metody.
    package func debugContourSnapshot() -> [ObjectID: [WorldPoint]] {
        Self.readContours(points: points, counts: counts, ids: bubbleIDs, stride: contourStride)
    }

    /// Szew testowy: kontury ze strony t−1, niezależnie od flagi `previousContoursValid` (puste bez strony t−1).
    package func debugPreviousContourSnapshot() -> [ObjectID: [WorldPoint]] {
        guard let previousPoints, let previousCounts else { return [:] }
        return Self.readContours(points: previousPoints, counts: previousCounts, ids: previousBubbleIDs, stride: contourStride)
    }

    private static func readContours(points: MTLBuffer, counts: MTLBuffer, ids: [ObjectID], stride: Int) -> [ObjectID: [WorldPoint]] {
        let countValues = counts.contents().bindMemory(to: UInt32.self, capacity: ids.count)
        let pointValues = points.contents().bindMemory(to: SIMD2<Float>.self, capacity: ids.count * stride)
        var result: [ObjectID: [WorldPoint]] = [:]
        for (index, id) in ids.enumerated() {
            let count = min(Int(countValues[index]), stride)
            result[id] = (0..<count).map { offset in
                let point = pointValues[index * stride + offset]
                return WorldPoint(point.x, point.y)
            }
        }
        return result
    }
}

/// Funkcje shaderów renderu: bańki z konturu GPU i bryły z trójkątów, z fragmentem materiału dla każdej z nich.
package struct NativeRenderFunctions {
    package let bubbleVertex: MTLFunction
    package let bodyVertex: MTLFunction
    package let bubbleFragment: MTLFunction
    package let bodyFragment: MTLFunction
    package let decalVertex: MTLFunction
    package let decalFragment: MTLFunction
}

/// Materiał renderu jednego obiektu; lustro `NativeRenderMaterial` w `NativeRenderKernels` (sonda ABI w NativeMetalShaderABITests).
package struct NativeRenderMaterial: Equatable, Sendable {
    /// RGBA w [0, 1].
    package var color: SIMD4<Float>
    package var outlineColor: SIMD4<Float>
    /// Szerokość obrysu w jednostkach świata, tryb mieszania (0 nieprzezroczysty, 1 alfa, 2 addytywny),
    /// tryb tekstury na bańce (0 przyklejony, 1 pod maską), zarezerwowane.
    package var parameters: SIMD4<Float>
    /// Przesunięcie xy i skala zw współrzędnych tekstury.
    package var uv: SIMD4<Float>

    package init(color: SIMD4<Float>, outlineColor: SIMD4<Float>, parameters: SIMD4<Float>, uv: SIMD4<Float>) {
        self.color = color; self.outlineColor = outlineColor; self.parameters = parameters; self.uv = uv
    }
}

/// Instancja bańki w kolejności rysowania: indeks rekordu w uchwycie, indeks materiału, indeks t−1 i α.
package struct NativeRenderInstance: Equatable, Sendable {
    package var bubble: UInt32
    package var material: UInt32
    /// Indeks rekordu bańki na stronie t−1 albo `noPrevious` (bez interpolacji).
    package var previous: UInt32
    /// Waga stanu t w obrazie między t−1 i t.
    package var alpha: Float
    package static let noPrevious: UInt32 = 0xFFFF_FFFF
    package init(bubble: UInt32, material: UInt32, previous: UInt32 = noPrevious, alpha: Float = 1) {
        self.bubble = bubble; self.material = material; self.previous = previous; self.alpha = alpha
    }
}

/// Wierzchołek trójkąta bryły: pozycja świata, współrzędne tekstury (`uv`: lokalny punkt w prostokącie otaczającym, V w dół) i `info` (materiał, początek i liczba punktów pierścienia).
package struct NativeRenderBodyVertex: Equatable, Sendable {
    package var world: SIMD2<Float>
    package var uv: SIMD2<Float>
    package var info: SIMD4<UInt32>
    package init(world: SIMD2<Float>, uv: SIMD2<Float>, info: SIMD4<UInt32>) {
        self.world = world; self.uv = uv; self.info = info
    }
}

/// Instancja naklejki; lustro `NativeDecalInstance` w `NativeRenderKernels` (sonda ABI w NativeMetalShaderABITests).
package struct NativeDecalInstance: Equatable, Sendable {
    package var color: SIMD4<Float>
    /// Bryła: kotwica xy, promień odniesienia i obrót. Bańka: kotwicę i promień daje rekord bańki w uchwycie, a `w` to α, waga
    /// stanu t w obrazie między t−1 i t (xyz nieużywane).
    package var placement: SIMD4<Float>
    /// Indeks bańki w uchwycie (`noBubble` dla bryły), tryb (`Mode`), indeks rekordu bańki na stronie t−1 (`noPrevious`: bez
    /// interpolacji; tylko bańka), reserved.
    package var info: SIMD4<UInt32>

    package static let noBubble: UInt32 = 0xFFFF_FFFF
    package static let noPrevious: UInt32 = 0xFFFF_FFFF
    package enum Mode: UInt32 { case image = 0, glyphAlpha = 1, glyphDistanceField = 2 }

    /// Dla bańki `previousBubbleIndex` i `alpha` opisują interpolację t−1 → t jak w `NativeRenderInstance`; dla bryły są ignorowane
    /// (poza bryły liczy CPU).
    package init(color: SIMD4<Float>, placement: SIMD4<Float>, bubbleIndex: UInt32, mode: Mode,
                 previousBubbleIndex: UInt32 = noPrevious, alpha: Float = 1) {
        self.color = color; self.placement = placement
        self.info = SIMD4(bubbleIndex, mode.rawValue, bubbleIndex == Self.noBubble ? Self.noPrevious : previousBubbleIndex, 0)
        if bubbleIndex != Self.noBubble { self.placement.w = alpha }
    }
}

/// Wierzchołek czworokąta naklejki: położenie względem kotwicy w jednostkach promienia odniesienia (przed obrotem),
/// współrzędne tekstury (wiersz 0 u góry) i indeks instancji.
package struct NativeDecalVertex: Equatable, Sendable {
    package var local: SIMD2<Float>
    package var uv: SIMD2<Float>
    package var info: SIMD4<UInt32>
    package init(local: SIMD2<Float>, uv: SIMD2<Float>, instance: UInt32) {
        self.local = local; self.uv = uv; self.info = SIMD4(instance, 0, 0, 0)
    }
}

package enum NativeRenderError: Error { case resourceUnavailable }
