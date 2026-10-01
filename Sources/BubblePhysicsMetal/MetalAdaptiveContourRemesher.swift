import Metal
import BubblePhysics

public struct MetalRemeshResult: Equatable, Sendable {
    public let contour: AdaptiveContour
    public let capacityGrowthRequired: Int?

    public init(contour: AdaptiveContour, capacityGrowthRequired: Int?) {
        self.contour = contour
        self.capacityGrowthRequired = capacityGrowthRequired
    }
}

private struct MetalRemeshVertex {
    var position: SIMD2<Float>
    var previousPosition: SIMD2<Float>
    var restLength: Float
    var stiffnessScale: Float
}

public final class MetalAdaptiveContourRemesher: @unchecked Sendable {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let markPipeline: MTLComputePipelineState
    private let planPipeline: MTLComputePipelineState
    private let compactPipeline: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        guard let library = MetalShaderLibrary.load(
            device: device,
            sourceName: "RemeshKernels",
            requiredFunctions: ["markRemeshEdges", "prefixRemeshPlan", "compactRemeshContour"]
        ), let mark = library.makeFunction(name: "markRemeshEdges"),
           let plan = library.makeFunction(name: "prefixRemeshPlan"),
           let compact = library.makeFunction(name: "compactRemeshContour"),
           let queue = device.makeCommandQueue()
        else { throw MetalSolverError.metalUnavailable }
        self.device = device
        self.queue = queue
        markPipeline = try device.makeComputePipelineState(function: mark)
        planPipeline = try device.makeComputePipelineState(function: plan)
        compactPipeline = try device.makeComputePipelineState(function: compact)
    }

    public func remesh(_ contour: AdaptiveContour, policy: RemeshPolicy, capacity: Int) throws -> MetalRemeshResult {
        let source = zip(contour.vertices, zip(contour.restLengths, contour.stiffnessScales)).map { vertex, material in
            MetalRemeshVertex(
                position: SIMD2(vertex.position.x, vertex.position.y),
                previousPosition: SIMD2(vertex.previousPosition.x, vertex.previousPosition.y),
                restLength: material.0,
                stiffnessScale: material.1
            )
        }
        let sourceBuffer = try makeBuffer(source)
        let markBuffer = try makeBuffer(Array(repeating: Int32(0), count: source.count))
        let destinationBuffer = try makeBuffer(Array(repeating: MetalRemeshVertex(position: .zero, previousPosition: .zero, restLength: 0, stiffnessScale: 0), count: max(1, capacity)))
        let actionBuffer = try makeBuffer([SIMD2<Int32>(0, -1)])
        let requiredBuffer = try makeBuffer([UInt32(source.count)])
        let growthBuffer = try makeBuffer([UInt32(0)])
        guard let commandBuffer = queue.makeCommandBuffer() else { throw MetalSolverError.commandEncodingFailed }

        try encodeMark(commandBuffer, sourceBuffer, markBuffer, count: source.count, policy: policy)
        try encodePlan(commandBuffer, markBuffer, actionBuffer, requiredBuffer, growthBuffer, count: source.count, capacity: capacity)
        try encodeCompact(commandBuffer, sourceBuffer, destinationBuffer, actionBuffer, requiredBuffer, growthBuffer, count: source.count)
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }

        let required = Int(requiredBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        let growth = Int(growthBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        guard growth == 0 else { return MetalRemeshResult(contour: contour, capacityGrowthRequired: growth) }
        let output = destinationBuffer.contents().bindMemory(to: MetalRemeshVertex.self, capacity: required)
        return MetalRemeshResult(
            contour: AdaptiveContour(
                vertices: (0..<required).map { index in
                    .init(
                        position: Vector2(x: output[index].position.x, y: output[index].position.y),
                        previousPosition: Vector2(x: output[index].previousPosition.x, y: output[index].previousPosition.y)
                    )
                },
                restLengths: (0..<required).map { output[$0].restLength },
                stiffnessScales: (0..<required).map { output[$0].stiffnessScale }
            ),
            capacityGrowthRequired: nil
        )
    }

    private func encodeMark(_ commandBuffer: MTLCommandBuffer, _ source: MTLBuffer, _ marks: MTLBuffer, count: Int, policy: RemeshPolicy) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        var count = UInt32(count), split = policy.splitLength, merge = policy.mergeLength
        encoder.setComputePipelineState(markPipeline)
        encoder.setBuffer(source, offset: 0, index: 0); encoder.setBuffer(marks, offset: 0, index: 1)
        encoder.setBytes(&count, length: 4, index: 2); encoder.setBytes(&split, length: 4, index: 3); encoder.setBytes(&merge, length: 4, index: 4)
        dispatch(encoder, pipeline: markPipeline, count: Int(count)); encoder.endEncoding()
    }

    private func encodePlan(_ commandBuffer: MTLCommandBuffer, _ marks: MTLBuffer, _ action: MTLBuffer, _ required: MTLBuffer, _ growth: MTLBuffer, count: Int, capacity: Int) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        var count = UInt32(count), capacity = UInt32(max(0, capacity))
        encoder.setComputePipelineState(planPipeline)
        encoder.setBuffer(marks, offset: 0, index: 0); encoder.setBuffer(action, offset: 0, index: 1)
        encoder.setBuffer(required, offset: 0, index: 2); encoder.setBuffer(growth, offset: 0, index: 3)
        encoder.setBytes(&count, length: 4, index: 4); encoder.setBytes(&capacity, length: 4, index: 5)
        dispatch(encoder, pipeline: planPipeline, count: 1); encoder.endEncoding()
    }

    private func encodeCompact(_ commandBuffer: MTLCommandBuffer, _ source: MTLBuffer, _ destination: MTLBuffer, _ action: MTLBuffer, _ required: MTLBuffer, _ growth: MTLBuffer, count: Int) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        var count = UInt32(count)
        encoder.setComputePipelineState(compactPipeline)
        encoder.setBuffer(source, offset: 0, index: 0); encoder.setBuffer(destination, offset: 0, index: 1)
        encoder.setBuffer(action, offset: 0, index: 2); encoder.setBuffer(required, offset: 0, index: 3)
        encoder.setBuffer(growth, offset: 0, index: 4); encoder.setBytes(&count, length: 4, index: 5)
        dispatch(encoder, pipeline: compactPipeline, count: 1); encoder.endEncoding()
    }

    private func makeBuffer<T>(_ values: [T]) throws -> MTLBuffer {
        let length = max(1, values.count) * MemoryLayout<T>.stride
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { throw MetalSolverError.bufferAllocationFailed }
        if !values.isEmpty { _ = values.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) } }
        return buffer
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, count: Int) {
        let width = min(pipeline.maxTotalThreadsPerThreadgroup, max(1, count))
        encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
    }
}

public final class MetalRemeshTransaction: @unchecked Sendable {
    public private(set) var capacity: Int
    private let remesher: MetalAdaptiveContourRemesher
    private var pending: (AdaptiveContour, RemeshPolicy)?

    public init(initialCapacity: Int, device: MTLDevice) throws {
        capacity = max(1, initialCapacity)
        remesher = try MetalAdaptiveContourRemesher(device: device)
    }

    public func apply(_ contour: AdaptiveContour, policy: RemeshPolicy) throws -> MetalRemeshResult {
        let result = try remesher.remesh(contour, policy: policy, capacity: capacity)
        if result.capacityGrowthRequired != nil { pending = (contour, policy) }
        return result
    }

    public func applyPendingAtFrameBoundary() throws -> MetalRemeshResult {
        guard let pending else { throw MetalSolverError.invalidTopologyCommand }
        capacity = max(capacity * 2, pending.0.vertices.count + 1)
        self.pending = nil
        return try apply(pending.0, policy: pending.1)
    }
}
