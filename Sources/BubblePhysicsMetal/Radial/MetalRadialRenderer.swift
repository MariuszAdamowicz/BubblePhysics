import BubblePhysics
import CoreGraphics
import Metal

public struct RadialRenderGeometry: Equatable, Sendable {
    public let fillVertices: [SIMD2<Float>]
}

public final class MetalRadialRenderer: @unchecked Sendable {
    private let device: MTLDevice
    private let worldBounds: AABB
    private let fillPipeline: MTLRenderPipelineState
    private let outlinePipeline: MTLRenderPipelineState
    private let polygonPipeline: MTLRenderPipelineState
    private let labelPipeline: MTLRenderPipelineState
    private let atlas: BubbleLabelAtlas
    private let labelUniforms: LabelUniforms

    private struct LabelUniforms {
        var uvOrigin: SIMD2<Float>
        var uvSize: SIMD2<Float>
        var halfSize: SIMD2<Float>
    }

    public init(
        device: MTLDevice,
        pixelFormat: MTLPixelFormat,
        worldBounds: AABB,
        label: String = "2"
    ) throws {
        self.device = device
        self.worldBounds = worldBounds
        let names = [
            "radialFillVertex", "radialOutlineVertex", "radialPolygonVertex",
            "radialColorFragment", "radialLabelVertex", "radialLabelFragment"
        ]
        guard
            let library = MetalShaderLibrary.load(
                device: device, sourceName: "RadialBubbleKernels", requiredFunctions: names
            ),
            let fillVertex = library.makeFunction(name: names[0]),
            let outlineVertex = library.makeFunction(name: names[1]),
            let polygonVertex = library.makeFunction(name: names[2]),
            let colorFragment = library.makeFunction(name: names[3]),
            let labelVertex = library.makeFunction(name: names[4]),
            let labelFragment = library.makeFunction(name: names[5])
        else { throw MetalSolverError.metalUnavailable }

        func pipeline(_ vertex: MTLFunction, _ fragment: MTLFunction) throws -> MTLRenderPipelineState {
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
        fillPipeline = try pipeline(fillVertex, colorFragment)
        outlinePipeline = try pipeline(outlineVertex, colorFragment)
        polygonPipeline = try pipeline(polygonVertex, colorFragment)
        labelPipeline = try pipeline(labelVertex, labelFragment)
        atlas = try BubbleLabelAtlas.build(labels: [label], device: device)
        guard let entry = atlas.entries[label] else { throw MetalSolverError.bufferAllocationFailed }
        let aspect = max(1, Float(label.count) * 0.62)
        labelUniforms = LabelUniforms(
            uvOrigin: entry.uvOrigin,
            uvSize: entry.uvSize,
            halfSize: SIMD2(12 * aspect, 16)
        )
    }

    public static func geometry(for state: RadialBubbleState) -> RadialRenderGeometry {
        let center = SIMD2(state.body.center.x, state.body.center.y)
        let points = state.surfacePoints.map { SIMD2($0.x, $0.y) }
        var fill: [SIMD2<Float>] = []
        fill.reserveCapacity(points.count * 3)
        for index in points.indices {
            fill.append(center)
            fill.append(points[index])
            fill.append(points[(index + 1) % points.count])
        }
        return RadialRenderGeometry(fillVertices: fill)
    }

    public static func labelPose(for state: RadialBubbleState) -> BubbleLabelPose {
        BubbleLabelPose(
            position: SIMD2(state.body.center.x, state.body.center.y),
            angleRadians: state.body.angle
        )
    }

    @discardableResult
    public func encode(
        frame: MetalRadialFrameResources,
        polygonVertices: [SIMD2<Float>],
        diagnostics: Bool,
        renderPass: MTLRenderPassDescriptor?,
        drawableSize: CGSize,
        commandBuffer: MTLCommandBuffer
    ) throws -> Bool {
        guard
            let renderPass,
            drawableSize.width > 0,
            drawableSize.height > 0,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else { return false }
        let viewport = MetalWorldViewport(worldBounds: worldBounds, drawableSize: drawableSize)
        var uniforms = SIMD4(
            viewport.worldToClipScale.x, viewport.worldToClipScale.y,
            viewport.worldToClipOffset.x, viewport.worldToClipOffset.y
        )
        var sensorCount = UInt32(frame.sensorCount)

        var fillColor = SIMD4<Float>(0.2, 0.72, 0.86, 0.78)
        encoder.setRenderPipelineState(fillPipeline)
        encoder.setVertexBuffer(frame.bodyBuffer, offset: 0, index: 0)
        encoder.setVertexBuffer(frame.surfacePointBuffer, offset: 0, index: 1)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 2)
        encoder.setVertexBytes(&sensorCount, length: MemoryLayout<UInt32>.stride, index: 3)
        encoder.setFragmentBytes(&fillColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: frame.sensorCount * 3)

        var outlineColor = SIMD4<Float>(0.04, 0.16, 0.22, 0.95)
        encoder.setRenderPipelineState(outlinePipeline)
        encoder.setVertexBuffer(frame.surfacePointBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setVertexBytes(&sensorCount, length: MemoryLayout<UInt32>.stride, index: 2)
        encoder.setFragmentBytes(&outlineColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.drawPrimitives(type: .lineStrip, vertexStart: 0, vertexCount: frame.sensorCount + 1)
        if diagnostics {
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: frame.sensorCount)
        }

        if !polygonVertices.isEmpty, let polygonBuffer = makeBuffer(polygonVertices) {
            var polygonColor = SIMD4<Float>(0.95, 0.38, 0.18, 0.88)
            encoder.setRenderPipelineState(polygonPipeline)
            encoder.setVertexBuffer(polygonBuffer, offset: 0, index: 0)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
            encoder.setFragmentBytes(&polygonColor, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: polygonVertices.count)
        }

        var label = labelUniforms
        encoder.setRenderPipelineState(labelPipeline)
        encoder.setVertexBuffer(frame.bodyBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.setVertexBytes(&label, length: MemoryLayout<LabelUniforms>.stride, index: 2)
        encoder.setFragmentTexture(atlas.texture, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()
        return true
    }

    private func makeBuffer<T>(_ values: [T]) -> MTLBuffer? {
        guard !values.isEmpty else { return nil }
        return values.withUnsafeBytes {
            device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
        }
    }
}
