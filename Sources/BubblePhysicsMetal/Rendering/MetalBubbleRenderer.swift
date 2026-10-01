import CoreGraphics
import Metal

public struct MetalBubbleSceneStatistics: Equatable, Sendable {
    public let bubbleCount: Int
    public let fillIndexCount: Int
    public let outlineIndexCount: Int
    public let diagnosticPointCount: Int
}

public final class MetalBubbleRenderer: @unchecked Sendable {
    public private(set) var sceneStatistics = MetalBubbleSceneStatistics(bubbleCount: 0, fillIndexCount: 0, outlineIndexCount: 0, diagnosticPointCount: 0)
    public private(set) var atlasBuildCount = 0
    public var labelCount: Int { atlas?.entries.count ?? 0 }

    private let device: MTLDevice
    private let pipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private var geometry: BubbleRenderGeometryBuffers?
    private var fillBuffer: MTLBuffer?
    private var outlineBuffer: MTLBuffer?
    private var pointBuffer: MTLBuffer?
    private var atlas: BubbleLabelAtlas?
    private var labelInstanceBuffer: MTLBuffer?
    private var labelInstanceCount = 0
    private var sceneKey: SceneKey?

    private struct SceneKey: Equatable { let ranges: [MetalBubbleRange]; let labels: [String] }
    private struct LabelInstance {
        let centerIndex: UInt32
        let materialIndex: UInt32
        let uvOrigin: SIMD2<Float>
        let uvSize: SIMD2<Float>
        let halfSize: SIMD2<Float>
    }

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat) throws {
        self.device = device
        guard let url = Bundle.module.url(forResource: "RenderKernels", withExtension: "metal"),
              let source = try? String(contentsOf: url),
              let library = try? device.makeLibrary(source: source, options: nil),
              let vertex = library.makeFunction(name: "bubbleVertex"), let fragment = library.makeFunction(name: "bubbleFragment"),
              let labelVertex = library.makeFunction(name: "labelVertex"), let labelFragment = library.makeFunction(name: "labelFragment")
        else { throw MetalSolverError.metalUnavailable }
        let descriptor = MTLRenderPipelineDescriptor(); descriptor.vertexFunction = vertex; descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = pixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        let labelDescriptor = MTLRenderPipelineDescriptor(); labelDescriptor.vertexFunction = labelVertex; labelDescriptor.fragmentFunction = labelFragment
        labelDescriptor.colorAttachments[0].pixelFormat = pixelFormat; labelDescriptor.colorAttachments[0].isBlendingEnabled = true
        labelDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; labelDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        labelPipeline = try device.makeRenderPipelineState(descriptor: labelDescriptor)
    }

    public func rebuildSceneResources(ranges: [MetalBubbleRange], labels: [String]) {
        let key = SceneKey(ranges: ranges, labels: labels)
        guard key != sceneKey else { return }
        let built = BubbleRenderGeometry.build(ranges: ranges); geometry = built
        fillBuffer = makeBuffer(built.fillIndices); outlineBuffer = makeBuffer(built.outlineIndices); pointBuffer = makeBuffer(built.diagnosticPointIndices)
        atlas = try? BubbleLabelAtlas.build(labels: labels, device: device); atlasBuildCount += 1; sceneKey = key
        if let atlas {
            let instances = zip(ranges, labels).compactMap { range, label -> LabelInstance? in
                guard let entry = atlas.entries[label], range.boundaryCount > 0 else { return nil }
                let aspect = max(1, Float(label.count) * 0.62)
                return LabelInstance(centerIndex: range.centerIndex, materialIndex: range.boundaryStart, uvOrigin: entry.uvOrigin, uvSize: entry.uvSize, halfSize: SIMD2(12 * aspect, 16))
            }
            labelInstanceBuffer = makeBuffer(instances); labelInstanceCount = instances.count
        }
        sceneStatistics = .init(bubbleCount: ranges.count, fillIndexCount: built.fillIndices.count, outlineIndexCount: built.outlineIndices.count, diagnosticPointCount: built.diagnosticPointIndices.count)
    }

    @discardableResult
    public func encode(frame: MetalFrameResources?, diagnostics: Bool, renderPass: MTLRenderPassDescriptor?, drawableSize: CGSize, commandBuffer: MTLCommandBuffer) throws -> Bool {
        guard let frame, let renderPass, drawableSize.width > 0, drawableSize.height > 0, let geometry, let fillBuffer,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return false }
        var uniforms = SIMD4<Float>(Float(drawableSize.width), Float(drawableSize.height), 0, 0)
        encoder.setRenderPipelineState(pipeline); encoder.setVertexBuffer(frame.particleBuffer, offset: 0, index: 0); encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        for span in geometry.bubbles {
            var color = Self.color(for: span.bubbleID)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawIndexedPrimitives(type: .triangle, indexCount: span.fillIndexRange.count, indexType: .uint32, indexBuffer: fillBuffer, indexBufferOffset: span.fillIndexRange.lowerBound * 4)
        }
        if let outlineBuffer {
            var color = SIMD4<Float>(0.08, 0.12, 0.2, 0.85); encoder.setFragmentBytes(&color, length: 16, index: 0)
            encoder.drawIndexedPrimitives(type: .line, indexCount: sceneStatistics.outlineIndexCount, indexType: .uint32, indexBuffer: outlineBuffer, indexBufferOffset: 0)
        }
        if diagnostics, let pointBuffer {
            var color = SIMD4<Float>(1, 0.3, 0.2, 1); encoder.setFragmentBytes(&color, length: 16, index: 0)
            encoder.drawIndexedPrimitives(type: .point, indexCount: sceneStatistics.diagnosticPointCount, indexType: .uint32, indexBuffer: pointBuffer, indexBufferOffset: 0)
        }
        if let atlas, let labelInstanceBuffer, labelInstanceCount > 0 {
            encoder.setRenderPipelineState(labelPipeline); encoder.setVertexBuffer(frame.particleBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1); encoder.setVertexBuffer(labelInstanceBuffer, offset: 0, index: 2)
            encoder.setFragmentTexture(atlas.texture, index: 0); encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: labelInstanceCount)
        }
        encoder.endEncoding(); return true
    }

    public static func color(for id: UInt32) -> SIMD4<Float> {
        var value = id &* 747_796_405 &+ 2_891_336_453; value = (value >> ((value >> 28) + 4)) ^ value
        let hue = Float(value & 1023) / 1024
        return SIMD4(0.25 + 0.65 * abs(sin(hue * 6.283)), 0.3 + 0.6 * abs(sin((hue + 0.33) * 6.283)), 0.35 + 0.55 * abs(sin((hue + 0.66) * 6.283)), 0.72)
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
    }
}
