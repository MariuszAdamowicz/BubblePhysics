import BubblePhysics
import CoreGraphics
import Metal

public struct MetalWorldViewport: Equatable, Sendable {
    public let worldBounds: AABB
    public let drawableSize: CGSize
    public let worldToClipScale: SIMD2<Float>
    public let worldToClipOffset: SIMD2<Float>

    public init(worldBounds: AABB, drawableSize: CGSize) {
        self.worldBounds = worldBounds
        self.drawableSize = drawableSize

        let worldWidth = max(worldBounds.maximum.x - worldBounds.minimum.x, Float.leastNonzeroMagnitude)
        let worldHeight = max(worldBounds.maximum.y - worldBounds.minimum.y, Float.leastNonzeroMagnitude)
        let drawableWidth = max(Float(drawableSize.width), Float.leastNonzeroMagnitude)
        let drawableHeight = max(Float(drawableSize.height), Float.leastNonzeroMagnitude)
        let pixelsPerWorldUnit = min(drawableWidth / worldWidth, drawableHeight / worldHeight)
        let renderedWidth = worldWidth * pixelsPerWorldUnit
        let renderedHeight = worldHeight * pixelsPerWorldUnit
        let viewportOrigin = SIMD2<Float>(
            (drawableWidth - renderedWidth) * 0.5,
            (drawableHeight - renderedHeight) * 0.5
        )

        worldToClipScale = SIMD2(
            2 * pixelsPerWorldUnit / drawableWidth,
            -2 * pixelsPerWorldUnit / drawableHeight
        )
        worldToClipOffset = SIMD2(
            -1 + 2 * (viewportOrigin.x - worldBounds.minimum.x * pixelsPerWorldUnit) / drawableWidth,
            1 - 2 * (viewportOrigin.y - worldBounds.minimum.y * pixelsPerWorldUnit) / drawableHeight
        )
    }

    public func worldToClip(_ point: SIMD2<Float>) -> SIMD2<Float> {
        point * worldToClipScale + worldToClipOffset
    }

    public func viewToWorld(_ point: SIMD2<Float>) -> SIMD2<Float> {
        let width = max(Float(drawableSize.width), Float.leastNonzeroMagnitude)
        let height = max(Float(drawableSize.height), Float.leastNonzeroMagnitude)
        let clip = SIMD2<Float>(2 * point.x / width - 1, 1 - 2 * point.y / height)
        return (clip - worldToClipOffset) / worldToClipScale
    }
}

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
    private let worldBounds: AABB
    private let pipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private let polygonPipeline: MTLRenderPipelineState
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
        let boundaryStart: UInt32
        let boundaryCount: UInt32
        let padding: UInt32 = 0
        let uvOrigin: SIMD2<Float>
        let uvSize: SIMD2<Float>
        let halfSize: SIMD2<Float>
    }

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat, worldBounds: AABB) throws {
        self.device = device
        self.worldBounds = worldBounds
        guard let library = MetalShaderLibrary.load(
                device: device,
                sourceName: "RenderKernels",
                requiredFunctions: ["bubbleVertex", "bubbleFragment", "labelVertex", "labelFragment", "polygonVertex"]
              ),
              let vertex = library.makeFunction(name: "bubbleVertex"), let fragment = library.makeFunction(name: "bubbleFragment"),
              let labelVertex = library.makeFunction(name: "labelVertex"), let labelFragment = library.makeFunction(name: "labelFragment"),
              let polygonVertex = library.makeFunction(name: "polygonVertex")
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
        let polygonDescriptor = MTLRenderPipelineDescriptor(); polygonDescriptor.vertexFunction = polygonVertex; polygonDescriptor.fragmentFunction = fragment
        polygonDescriptor.colorAttachments[0].pixelFormat = pixelFormat; polygonDescriptor.colorAttachments[0].isBlendingEnabled = true
        polygonDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha; polygonDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        polygonPipeline = try device.makeRenderPipelineState(descriptor: polygonDescriptor)
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
                return LabelInstance(centerIndex: range.centerIndex, boundaryStart: range.boundaryStart, boundaryCount: range.boundaryCount, uvOrigin: entry.uvOrigin, uvSize: entry.uvSize, halfSize: SIMD2(12 * aspect, 16))
            }
            labelInstanceBuffer = makeBuffer(instances); labelInstanceCount = instances.count
        }
        sceneStatistics = .init(bubbleCount: ranges.count, fillIndexCount: built.fillIndices.count, outlineIndexCount: built.outlineIndices.count, diagnosticPointCount: built.diagnosticPointIndices.count)
    }

    @discardableResult
    public func encode(frame: MetalFrameResources?, diagnostics: Bool, renderPass: MTLRenderPassDescriptor?, drawableSize: CGSize, commandBuffer: MTLCommandBuffer) throws -> Bool {
        guard let frame, let renderPass, drawableSize.width > 0, drawableSize.height > 0, let geometry, let fillBuffer,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return false }
        let viewport = MetalWorldViewport(worldBounds: worldBounds, drawableSize: drawableSize)
        var uniforms = SIMD4<Float>(
            viewport.worldToClipScale.x,
            viewport.worldToClipScale.y,
            viewport.worldToClipOffset.x,
            viewport.worldToClipOffset.y
        )
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
        if frame.polygonVertexCount >= 3 {
            var color = SIMD4<Float>(0.95, 0.38, 0.18, 0.88)
            encoder.setRenderPipelineState(polygonPipeline); encoder.setVertexBuffer(frame.polygonVertexBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1); encoder.setFragmentBytes(&color, length: 16, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: frame.polygonVertexCount)
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
