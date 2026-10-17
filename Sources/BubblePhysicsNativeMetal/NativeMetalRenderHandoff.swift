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

    init(points: MTLBuffer, counts: MTLBuffer, bubbles: MTLBuffer,
         bubbleIDs: [ObjectID], contourStride: Int) {
        self.points = points
        self.counts = counts
        self.bubbles = bubbles
        self.bubbleIDs = bubbleIDs
        self.contourStride = contourStride
    }

    package static func makeFunctions(device: MTLDevice) throws -> (vertex: MTLFunction, fragment: MTLFunction) {
        guard let url = Bundle.module.url(forResource: "NativeRenderKernels", withExtension: "metal-source") else {
            throw NativeRenderError.resourceUnavailable
        }
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let vertex = library.makeFunction(name: "nativeContourVertex"),
              let fragment = library.makeFunction(name: "nativeTechnicalFragment") else {
            throw NativeRenderError.resourceUnavailable
        }
        return (vertex, fragment)
    }

    package func bind(_ encoder: MTLRenderCommandEncoder, viewport: Viewport) {
        encoder.setVertexBuffer(points, offset: 0, index: 0)
        encoder.setVertexBuffer(counts, offset: 0, index: 1)
        encoder.setVertexBuffer(bubbles, offset: 0, index: 4)
        var values = SIMD4<Float>(viewport.center.x, viewport.center.y, viewport.size.x, viewport.size.y)
        encoder.setVertexBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        var stride = UInt32(contourStride)
        encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 3)
        var mode: UInt32 = 0
        encoder.setVertexBytes(&mode, length: MemoryLayout<UInt32>.stride, index: 6)
    }

    package func drawAll(_ encoder: MTLRenderCommandEncoder) {
        guard bubbleCount > 0 else { return }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
            vertexCount: contourStride * 3, instanceCount: bubbleCount)
    }

    package func draw(_ encoder: MTLRenderCommandEncoder, bubbleIndex: Int) {
        guard bubbleIndex >= 0, bubbleIndex < bubbleCount else { return }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0,
            vertexCount: contourStride * 3, instanceCount: 1, baseInstance: bubbleIndex)
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

package enum NativeRenderError: Error { case resourceUnavailable }
