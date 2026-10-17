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
        published.handoff.bind(encoder, viewport: viewport)
        if published.items.count == published.handoff.bubbleCount,
           published.items.allSatisfy({ $0?.shader == .technical }) {
            encoder.setRenderPipelineState(technical)
            published.handoff.drawAll(encoder)
            return
        }
        for (index, item) in published.items.enumerated() {
            guard let item else { continue }
            switch item.shader {
            case .technical:
                encoder.setRenderPipelineState(technical)
            case .custom(let key):
                if let pipeline = customPipelines[key] {
                    encoder.setRenderPipelineState(pipeline.state)
                    pipeline.encodeChannels(encoder, item.channels)
                } else {
                    encoder.setRenderPipelineState(technical)
                }
            }
            published.handoff.draw(encoder, bubbleIndex: index)
        }
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
