import Metal
import BubblePhysicsModel

/// Nieprzezroczysty uchwyt do kompletnej, opublikowanej klatki GPU.
/// Bufory pozostają własnością backendu i nie są częścią publicznego API gry.
@MainActor
package final class NativeMetalRenderHandoff {
    private let points: MTLBuffer
    private let counts: MTLBuffer
    private let bubbles: MTLBuffer
    package let bubbleIDs: [ObjectID]
    package var bubbleCount: Int { bubbleIDs.count }
    package let contourStride: Int
    /// Rozmiar jednego rekordu `RenderBubble` w ABI shadera renderu (ten sam układ co `NativeBubble`).
    package static let bubbleRecordByteCount = MemoryLayout<NativeMetalBubble>.stride

    /// Indeks rekordu bańki w uchwycie; budowany raz na uchwyt przy pierwszym użyciu przez renderer.
    package private(set) lazy var bubbleIndexByID: [ObjectID: Int] = Dictionary(
        uniqueKeysWithValues: bubbleIDs.enumerated().map { ($0.element, $0.offset) })

    init(points: MTLBuffer, counts: MTLBuffer, bubbles: MTLBuffer,
         bubbleIDs: [ObjectID], contourStride: Int) {
        self.points = points
        self.counts = counts
        self.bubbles = bubbles
        self.bubbleIDs = bubbleIDs
        self.contourStride = contourStride
    }

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
              let bodyFragment = library.makeFunction(name: "nativeBodyFragment") else {
            throw NativeRenderError.resourceUnavailable
        }
        let functions = NativeRenderFunctions(bubbleVertex: bubbleVertex, bodyVertex: bodyVertex,
            bubbleFragment: bubbleFragment, bodyFragment: bodyFragment)
        compiledFunctions[device.registryID] = functions
        return functions
    }

    /// Wiąże bufory konturów baniek i bufor instancji (kolejność rysowania); bańki idą potem ciągami przez `drawBubbles`.
    package func bindBubbles(_ encoder: MTLRenderCommandEncoder, viewport: Viewport, instances: MTLBuffer, instanceOffset: Int) {
        encoder.setVertexBuffer(points, offset: 0, index: 0)
        encoder.setVertexBuffer(counts, offset: 0, index: 1)
        encoder.setVertexBuffer(bubbles, offset: 0, index: 4)
        encoder.setVertexBuffer(instances, offset: instanceOffset, index: 7)
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

    /// Wyłącznie adapter diagnostyczny. Produkcyjny renderer nie wywołuje tej metody.
    package func debugContourSnapshot() -> [ObjectID: [WorldPoint]] {
        let countValues = counts.contents().bindMemory(to: UInt32.self, capacity: bubbleCount)
        let pointValues = points.contents().bindMemory(to: SIMD2<Float>.self,
            capacity: bubbleCount * contourStride)
        var result: [ObjectID: [WorldPoint]] = [:]
        for (index, id) in bubbleIDs.enumerated() {
            let count = min(Int(countValues[index]), contourStride)
            result[id] = (0..<count).map { offset in
                let point = pointValues[index * contourStride + offset]
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

/// Instancja bańki w kolejności rysowania: indeks rekordu w uchwycie i indeks materiału.
package struct NativeRenderInstance: Equatable, Sendable {
    package var bubble: UInt32
    package var material: UInt32
    package init(bubble: UInt32, material: UInt32) { self.bubble = bubble; self.material = material }
}

/// Wierzchołek trójkąta bryły: pozycja świata, współrzędne lokalne i `info` (materiał, początek i liczba punktów pierścienia).
package struct NativeRenderBodyVertex: Equatable, Sendable {
    package var world: SIMD2<Float>
    package var local: SIMD2<Float>
    package var info: SIMD4<UInt32>
    package init(world: SIMD2<Float>, local: SIMD2<Float>, info: SIMD4<UInt32>) {
        self.world = world; self.local = local; self.info = info
    }
}

package enum NativeRenderError: Error { case resourceUnavailable }
