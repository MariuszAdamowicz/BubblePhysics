import BubblePhysics
import Metal
import BubblePhysicsNativeMetal

public enum BubblePhysicsMetalRenderError: Error {
    case deviceMismatch, missingColorTarget, renderEncoderUnavailable
}

/// Renderuje opublikowaną klatkę bez materializacji konturów na CPU.
@MainActor
public final class BubblePhysicsMetalRender {
    private let device: MTLDevice
    private let vertexFunction: MTLFunction
    private let technicalFragment: MTLFunction
    private var technicalPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    public var customPipelines: [String: RenderStylePipeline]

    public init(device: MTLDevice, customPipelines: [String: RenderStylePipeline] = [:]) throws {
        self.device = device
        let functions = try NativeMetalRenderHandoff.makeFunctions(device: device)
        self.vertexFunction = functions.vertex
        self.technicalFragment = functions.fragment
        self.customPipelines = customPipelines
    }

    /// Ta funkcja definiuje ABI wierzchołków dla niestandardowego fragment shaderu.
    public func makeContourVertexFunction() -> MTLFunction { vertexFunction }

    public func encode(world: BubbleWorld, viewport: Viewport, commandBuffer: MTLCommandBuffer,
                       renderPassDescriptor: MTLRenderPassDescriptor) throws {
        guard commandBuffer.device === device else { throw BubblePhysicsMetalRenderError.deviceMismatch }
        guard let color = renderPassDescriptor.colorAttachments[0].texture else {
            throw BubblePhysicsMetalRenderError.missingColorTarget
        }
        let technical = try technicalPipeline(format: color.pixelFormat)
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
            throw BubblePhysicsMetalRenderError.renderEncoderUnavailable
        }
        defer { encoder.endEncoding() }
        encoder.label = "bubble-physics.direct-render"
        guard let published = world.renderState else { return }
        if let handoff = published.handoff {
            handoff.bind(encoder, viewport: viewport)
            if published.items.count == handoff.bubbleCount,
               published.items.allSatisfy({ $0?.shader == .technical }) {
                encoder.setRenderPipelineState(technical)
                handoff.drawAll(encoder)
            } else {
                for (index, item) in published.items.enumerated() {
                    guard let item else { continue }
                    selectPipeline(for: item, encoder: encoder, technical: technical)
                    handoff.draw(encoder, bubbleIndex: index)
                }
            }
        }
        for shape in published.shapes {
            let triangles = Self.triangulate(shape.vertices)
            guard !triangles.isEmpty else { continue }
            let coordinates = triangles.map { SIMD2<Float>($0.x, $0.y) }
            guard let buffer = device.makeBuffer(bytes: coordinates,
                length: coordinates.count * MemoryLayout<SIMD2<Float>>.stride) else { continue }
            let retained = RetainedShapeBuffer(buffer)
            commandBuffer.addCompletedHandler { _ in withExtendedLifetime(retained) {} }
            encoder.setVertexBuffer(buffer, offset: 0, index: 5)
            // Metal argument validation requires all declared slots to be bound.
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBuffer(buffer, offset: 0, index: 1)
            encoder.setVertexBuffer(buffer, offset: 0, index: 4)
            var values = SIMD4<Float>(viewport.center.x, viewport.center.y, viewport.size.x, viewport.size.y)
            encoder.setVertexBytes(&values, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            var stride: UInt32 = 0
            encoder.setVertexBytes(&stride, length: MemoryLayout<UInt32>.stride, index: 3)
            var mode: UInt32 = 1
            encoder.setVertexBytes(&mode, length: MemoryLayout<UInt32>.stride, index: 6)
            selectPipeline(for: shape.item, encoder: encoder, technical: technical)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: coordinates.count)
        }
    }

    private func selectPipeline(for item: BubbleWorldRenderItem, encoder: MTLRenderCommandEncoder,
                                technical: MTLRenderPipelineState) {
        switch item.shader {
        case .technical: encoder.setRenderPipelineState(technical)
        case .custom(let key):
            if let pipeline = customPipelines[key] {
                encoder.setRenderPipelineState(pipeline.state)
                pipeline.encodeChannels(encoder, item.channels)
            } else { encoder.setRenderPipelineState(technical) }
        }
    }

    /// Ear clipping obsługuje także wklęsłe proste pierścienie z modelu.
    private static func triangulate(_ ring: [WorldPoint]) -> [WorldPoint] {
        guard ring.count >= 3 else { return [] }
        let area = ring.indices.reduce(Float.zero) { sum, i in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return sum + a.x * b.y - b.x * a.y
        }
        let sign: Float = area >= 0 ? 1 : -1
        var indices = Array(ring.indices)
        var output: [WorldPoint] = []
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
                output += [a, b, c]
                indices.remove(at: i)
                clipped = true
                break
            }
            if !clipped { return [] }
        }
        output += indices.map { ring[$0] }
        return output
    }

    private func technicalPipeline(format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let pipeline = technicalPipelines[format] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = technicalFragment
        descriptor.colorAttachments[0].pixelFormat = format
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        technicalPipelines[format] = pipeline
        return pipeline
    }
}

private struct RetainedShapeBuffer: @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
}
