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
    private let presentationFragment: MTLFunction
    /// W trybie wielokąta shader nie czyta `bubbles`, lecz walidacja Metal
    /// wymaga bufora o pełnym ABI `RenderBubble` (144 bajtów).
    private let polygonBubblePlaceholder: MTLBuffer
    private var technicalPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    private var presentationPipelines: [MTLPixelFormat: MTLRenderPipelineState] = [:]
    public var customPipelines: [String: RenderStylePipeline]

    public init(device: MTLDevice, customPipelines: [String: RenderStylePipeline] = [:]) throws {
        self.device = device
        guard let polygonBubblePlaceholder = device.makeBuffer(length: 144, options: .storageModeShared) else {
            throw BubblePhysicsMetalRenderError.renderEncoderUnavailable
        }
        self.polygonBubblePlaceholder = polygonBubblePlaceholder
        let functions = try NativeMetalRenderHandoff.makeFunctions(device: device)
        self.vertexFunction = functions.vertex
        self.technicalFragment = functions.fragment
        let presentationSource = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 worldPosition; float2 bubbleCenter; float bubbleRadius; };
        struct SemanticPresentation { ulong value; uint isGrabbed; uint padding; };
        bool segment(float2 point, int digit, int index) {
            bool enabled[10][7] = {
                {true, true, true, true, true, true, false}, {false, true, true, false, false, false, false},
                {true, true, false, true, true, false, true}, {true, true, true, true, false, false, true},
                {false, true, true, false, false, true, true}, {true, false, true, true, false, true, true},
                {true, false, true, true, true, true, true}, {true, true, true, false, false, false, false},
                {true, true, true, true, true, true, true}, {true, true, true, true, false, true, true}
            };
            if (!enabled[digit][index]) return false;
            if (index == 0) return abs(point.y - 0.72) < 0.12 && abs(point.x) < 0.55;
            if (index == 1) return abs(point.x - 0.55) < 0.12 && point.y > 0.0 && point.y < 0.72;
            if (index == 2) return abs(point.x - 0.55) < 0.12 && point.y < 0.0 && point.y > -0.72;
            if (index == 3) return abs(point.y + 0.72) < 0.12 && abs(point.x) < 0.55;
            if (index == 4) return abs(point.x + 0.55) < 0.12 && point.y < 0.0 && point.y > -0.72;
            if (index == 5) return abs(point.x + 0.55) < 0.12 && point.y > 0.0 && point.y < 0.72;
            return abs(point.y) < 0.12 && abs(point.x) < 0.55;
        }
        fragment float4 semanticPresentation(V in [[stage_in]], constant SemanticPresentation &presentation [[buffer(0)]]) {
            ulong remaining = presentation.value;
            int count = 1;
            while (remaining >= 10 && count < 19) { remaining /= 10; count++; }
            float width = min(0.52, 1.65 / float(count));
            float2 local = (in.worldPosition - in.bubbleCenter) / max(in.bubbleRadius, 0.001);
            int glyphIndex = int(floor((local.x + width * float(count) * 0.5) / width));
            bool glyph = false;
            if (glyphIndex >= 0 && glyphIndex < count && abs(local.y) < 0.54) {
                ulong divisor = 1;
                for (int i = 0; i < count - glyphIndex - 1; i++) divisor *= 10;
                int digit = int((presentation.value / divisor) % 10);
                float glyphCenter = -width * float(count) * 0.5 + width * (float(glyphIndex) + 0.5);
                float2 point = float2((local.x - glyphCenter) / (width * 0.5), local.y / 0.54);
                for (int i = 0; i < 7; i++) glyph = glyph || segment(point, digit, i);
            }
            int palette = int((presentation.value * 5 + presentation.value / 2) % 7);
            float3 fill = palette == 0 ? float3(0.45, 0.32, 0.82) :
                          palette == 1 ? float3(0.18, 0.65, 0.42) :
                          palette == 2 ? float3(0.18, 0.48, 0.86) :
                          palette == 3 ? float3(0.84, 0.32, 0.49) :
                          palette == 4 ? float3(0.88, 0.52, 0.16) :
                          palette == 5 ? float3(0.12, 0.62, 0.64) : float3(0.62, 0.38, 0.72);
            if (presentation.isGrabbed != 0) fill = mix(fill, float3(1.0, 0.68, 0.12), 0.45);
            float3 ink = float3(1.0, 1.0, 1.0);
            return float4(glyph ? ink : fill, 1.0);
        }
        """
        let presentationLibrary = try device.makeLibrary(source: presentationSource, options: nil)
        guard let presentationFragment = presentationLibrary.makeFunction(name: "semanticPresentation") else {
            throw BubblePhysicsMetalRenderError.renderEncoderUnavailable
        }
        self.presentationFragment = presentationFragment
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
               published.items.allSatisfy({ $0?.shader == .technical && $0?.bubblePresentation == nil }) {
                encoder.setRenderPipelineState(technical)
                handoff.drawAll(encoder)
            } else {
                for (index, item) in published.items.enumerated() {
                    guard let item else { continue }
                    selectPipeline(for: item, encoder: encoder, technical: technical)
                    handoff.draw(encoder, bubbleIndex: index)
                    if let presentation = item.bubblePresentation {
                        encoder.setRenderPipelineState(try presentationPipeline(format: color.pixelFormat))
                        handoff.drawPresentation(encoder, bubbleIndex: index,
                            value: presentation.value, isGrabbed: presentation.isGrabbed)
                    }
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
            encoder.setVertexBuffer(polygonBubblePlaceholder, offset: 0, index: 4)
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

    private func presentationPipeline(format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        if let pipeline = presentationPipelines[format] { return pipeline }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = presentationFragment
        descriptor.colorAttachments[0].pixelFormat = format
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        presentationPipelines[format] = pipeline
        return pipeline
    }

}

private struct RetainedShapeBuffer: @unchecked Sendable {
    let buffer: MTLBuffer
    init(_ buffer: MTLBuffer) { self.buffer = buffer }
}
