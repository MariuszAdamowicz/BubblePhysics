import BubblePhysics
import CoreGraphics
import Metal

public struct MetalRadialWorldDrawRange: Equatable, Sendable {
    public let bubbleIndex: Int
    public let sensorStart: Int
    public let sensorCount: Int
    public var fillVertexCount: Int { sensorCount * 3 }
    public var outlineVertexCount: Int { sensorCount + 1 }
}

public final class MetalRadialWorldRenderer: @unchecked Sendable {
    private struct LabelUniforms {
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        var halfSize: SIMD2<Float>
    }

    private let device: MTLDevice
    private let worldBounds: AABB
    private let fillPipeline: MTLRenderPipelineState
    private let outlinePipeline: MTLRenderPipelineState
    private let polygonPipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private var atlas: BubbleLabelAtlas?
    private var labelUniforms: [LabelUniforms] = []

    public init(device: MTLDevice, pixelFormat: MTLPixelFormat, worldBounds: AABB) throws {
        self.device = device
        self.worldBounds = worldBounds
        let names = [
            "radialFillVertex", "radialOutlineVertex", "radialPolygonVertex",
            "radialColorFragment", "radialLabelVertex", "radialLabelFragment"
        ]
        guard let library = MetalShaderLibrary.load(
            device: device, sourceName: "RadialBubbleKernels", requiredFunctions: names
        ), let fill = library.makeFunction(name: names[0]),
        let outline = library.makeFunction(name: names[1]),
        let polygon = library.makeFunction(name: names[2]),
        let color = library.makeFunction(name: names[3]),
        let label = library.makeFunction(name: names[4]),
        let labelFragment = library.makeFunction(name: names[5]) else {
            throw MetalSolverError.metalUnavailable
        }
        func makePipeline(_ vertex: MTLFunction, _ fragment: MTLFunction) throws -> MTLRenderPipelineState {
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertex
            descriptor.fragmentFunction = fragment
            descriptor.colorAttachments[0].pixelFormat = pixelFormat
            descriptor.stencilAttachmentPixelFormat = .stencil8
            descriptor.colorAttachments[0].isBlendingEnabled = true
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: descriptor)
        }
        fillPipeline = try makePipeline(fill, color)
        outlinePipeline = try makePipeline(outline, color)
        polygonPipeline = try makePipeline(polygon, color)
        labelPipeline = try makePipeline(label, labelFragment)
    }

    public func rebuildScene(labels: [String]) throws {
        atlas = try BubbleLabelAtlas.build(labels: labels, device: device)
        labelUniforms = try labels.map { label in
            guard let entry = atlas?.entries[label] else { throw MetalSolverError.bufferAllocationFailed }
            return LabelUniforms(
                uvOrigin: entry.uvOrigin, uvSize: entry.uvSize,
                halfSize: SIMD2(12 * max(1, Float(label.count) * 0.62), 16)
            )
        }
    }

    public static func drawPlan(for world: RadialWorldState) -> [MetalRadialWorldDrawRange] {
        world.ranges.map {
            MetalRadialWorldDrawRange(
                bubbleIndex: $0.bubbleIndex, sensorStart: $0.sensorStart,
                sensorCount: $0.sensorCount
            )
        }
    }

    public static func labelPoses(for world: RadialWorldState) -> [BubbleID: BubbleLabelPose] {
        Dictionary(uniqueKeysWithValues: world.bubbles.map {
            ($0.id, BubbleLabelPose(
                position: SIMD2($0.body.center.x, $0.body.center.y),
                angleRadians: $0.body.angle
            ))
        })
    }

    public static func geometry(for world: RadialWorldState) -> [SIMD2<Float>] {
        world.bubbles.flatMap { MetalRadialRenderer.geometry(for: $0).fillVertices }
    }

    @discardableResult
    public func encode(
        frame: MetalRadialWorldFrameResources,
        polygonVertices: [SIMD2<Float>], diagnostics: Bool,
        renderPass: MTLRenderPassDescriptor?, drawableSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        guard let renderPass, drawableSize.width > 0, drawableSize.height > 0,
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass) else { return false }
        let viewport = MetalWorldViewport(worldBounds: worldBounds, drawableSize: drawableSize)
        var viewportUniforms = SIMD4(
            viewport.worldToClipScale.x, viewport.worldToClipScale.y,
            viewport.worldToClipOffset.x, viewport.worldToClipOffset.y
        )
        for range in frame.ranges {
            var sensorCount = UInt32(range.sensorCount)
            var fillColor = SIMD4<Float>(0.2, 0.72, 0.86, 0.78)
            encoder.setRenderPipelineState(fillPipeline)
            encoder.setVertexBuffer(frame.bodyBuffer, offset: range.bubbleIndex * MemoryLayout<MetalRadialBody>.stride, index: 0)
            encoder.setVertexBuffer(frame.surfacePointBuffer, offset: range.sensorStart * MemoryLayout<SIMD2<Float>>.stride, index: 1)
            encoder.setVertexBytes(&viewportUniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
            encoder.setVertexBytes(&sensorCount, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.setFragmentBytes(&fillColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: range.sensorCount * 3)

            var outlineColor = SIMD4<Float>(0.04, 0.16, 0.22, 0.95)
            encoder.setRenderPipelineState(outlinePipeline)
            encoder.setVertexBuffer(frame.surfacePointBuffer, offset: range.sensorStart * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            encoder.setVertexBytes(&viewportUniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setVertexBytes(&sensorCount, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.setFragmentBytes(&outlineColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: range.sensorCount + 1)
            if diagnostics { encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: range.sensorCount) }
        }
        if !polygonVertices.isEmpty, let buffer = makeBuffer(polygonVertices) {
            var color = SIMD4<Float>(0.95, 0.38, 0.18, 0.88)
            encoder.setRenderPipelineState(polygonPipeline)
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.setVertexBytes(&viewportUniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: polygonVertices.count)
        }
        if let atlas {
            encoder.setFragmentTexture(atlas.texture, index: 0)
            for range in frame.ranges where labelUniforms.indices.contains(range.bubbleIndex) {
                var label = labelUniforms[range.bubbleIndex]
                encoder.setRenderPipelineState(labelPipeline)
                encoder.setVertexBuffer(frame.bodyBuffer, offset: range.bubbleIndex * MemoryLayout<MetalRadialBody>.stride, index: 0)
                encoder.setVertexBytes(&viewportUniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
                encoder.setVertexBytes(&label, length: MemoryLayout<LabelUniforms>.stride, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            }
        }
        encoder.endEncoding()
        return true
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        values.withUnsafeBytes {
            guard let base = $0.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: $0.count, options: .storageModeShared)
        }
    }
}
