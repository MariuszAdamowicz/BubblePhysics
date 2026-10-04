import Foundation
import Metal
import BubblePhysicsReference

struct ReferenceMetalOperatorResult {
    let residual: [ReferenceVector2]
    let jacobianVector: [ReferenceVector2]
    let inverseDiagonal: [ReferenceVector2]
    let dotProduct: Float
}

enum ReferenceMetalOperatorError: Error {
    case invalidInput, commandSetupFailed, executionFailed(String), evaluationInFlight
}

private struct ReferenceMetalOperatorParameters {
    var counts: SIMD4<UInt32>
    var physics: SIMD4<Float>
    var drag: SIMD4<Float>
}

/// Numerical operators for the iOS reference backend. macOS is a test host.
/// World stepping and backend selection are implemented separately.
public final class ReferenceMetalSolver {
    public let device: MTLDevice
    public let loadedFunctionNames: Set<String>
    private let residualPipeline: MTLComputePipelineState
    private let jacobianPipeline: MTLComputePipelineState
    private let diagonalPipeline: MTLComputePipelineState
    private let dotPipeline: MTLComputePipelineState
    private let pcgInitializePipeline: MTLComputePipelineState
    private let pcgAdvancePipeline: MTLComputePipelineState
    private let pcgDirectionPipeline: MTLComputePipelineState
    private let pcgFinalizePipeline: MTLComputePipelineState
    private let commandQueue: MTLCommandQueue
    private var operatorBuffers: [String: MTLBuffer] = [:]
    private var evaluationInFlight = false
    let capacityManager: ReferenceMetalCapacityManager

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        guard let device,
              let url = Bundle.module.url(forResource: "ReferenceNewtonPCGKernels", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8),
              let library = try? device.makeLibrary(source: source, options: options),
              let function = library.makeFunction(name: "referenceBuildResidual"),
              let jacobian = library.makeFunction(name: "referenceApplyJacobian"),
              let diagonal = library.makeFunction(name: "referenceBuildInverseDiagonal"),
              let dot = library.makeFunction(name: "referenceReduceDot"),
              let pcgInitialize = library.makeFunction(name: "referencePCGInitialize"),
              let pcgAdvance = library.makeFunction(name: "referencePCGAdvance"),
              let pcgDirection = library.makeFunction(name: "referencePCGUpdateDirection"),
              let pcgFinalize = library.makeFunction(name: "referencePCGFinalize"),
              let pipeline = try? device.makeComputePipelineState(function: function),
              let jacobianPipeline = try? device.makeComputePipelineState(function: jacobian),
              let diagonalPipeline = try? device.makeComputePipelineState(function: diagonal),
              let dotPipeline = try? device.makeComputePipelineState(function: dot),
              let pcgInitializePipeline = try? device.makeComputePipelineState(function: pcgInitialize),
              let pcgAdvancePipeline = try? device.makeComputePipelineState(function: pcgAdvance),
              let pcgDirectionPipeline = try? device.makeComputePipelineState(function: pcgDirection),
              let pcgFinalizePipeline = try? device.makeComputePipelineState(function: pcgFinalize),
              dotPipeline.maxTotalThreadsPerThreadgroup >= 256,
              let commandQueue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        capacityManager = ReferenceMetalCapacityManager(device: device)
        residualPipeline = pipeline
        self.jacobianPipeline = jacobianPipeline
        self.diagonalPipeline = diagonalPipeline
        self.dotPipeline = dotPipeline
        self.pcgInitializePipeline = pcgInitializePipeline
        self.pcgAdvancePipeline = pcgAdvancePipeline
        self.pcgDirectionPipeline = pcgDirectionPipeline
        self.pcgFinalizePipeline = pcgFinalizePipeline
        self.commandQueue = commandQueue
        loadedFunctionNames = [function.name, jacobian.name, diagonal.name, dot.name,
                              pcgInitialize.name, pcgAdvance.name, pcgDirection.name, pcgFinalize.name]
    }

    func evaluateOperatorsForTesting(snapshot: ReferenceMetalSnapshot, endCenters: [ReferenceVector2],
                                     vector: [ReferenceVector2]) async throws -> ReferenceMetalOperatorResult {
        guard !evaluationInFlight else { throw ReferenceMetalOperatorError.evaluationInFlight }
        let count = snapshot.bubbles.count
        guard endCenters.count == count, vector.count == count,
              snapshot.centers.count == count, snapshot.velocities.count == count,
              let bubbleCount = UInt32(exactly: count),
              let contactCount = UInt32(exactly: snapshot.contacts.count),
              snapshot.configuration.timeStep.isFinite, snapshot.configuration.timeStep > 0
        else { throw ReferenceMetalOperatorError.invalidInput }
        evaluationInFlight = true
        defer { evaluationInFlight = false }

        let inputs = try [upload(snapshot.bubbles, name: "bubbles"),
                          upload(snapshot.centers, name: "start"),
                          upload(snapshot.velocities, name: "velocity"),
                          upload(snapshot.contacts, name: "contacts"),
                          upload(endCenters.map { SIMD2($0.x, $0.y) }, name: "end"),
                          upload(vector.map { SIMD2($0.x, $0.y) }, name: "vector")]
        let residual = try buffer(name: "residual", count: count, stride: MemoryLayout<SIMD2<Float>>.stride)
        let jacobian = try buffer(name: "jacobian", count: count, stride: MemoryLayout<SIMD2<Float>>.stride)
        let diagonal = try buffer(name: "diagonal", count: count, stride: MemoryLayout<SIMD2<Float>>.stride)
        let blockCount = count / 256 + (count % 256 == 0 ? 0 : 1)
        let blocks = try buffer(name: "dotBlocks", count: blockCount, stride: MemoryLayout<Float>.stride)
        let dot = try buffer(name: "dot", count: 1, stride: MemoryLayout<Float>.stride)
        guard let command = commandQueue.makeCommandBuffer() else { throw ReferenceMetalOperatorError.commandSetupFailed }
        let config = snapshot.configuration
        var parameters = ReferenceMetalOperatorParameters(counts: SIMD4(bubbleCount, contactCount, 0, 0),
            physics: SIMD4(config.timeStep, config.contactStiffness, config.nonlinearStiffening, config.contactDamping),
            drag: SIMD4(config.linearDamping, 0, 0, 0))
        if count > 0 {
            for (pipeline, output) in [(residualPipeline, residual), (jacobianPipeline, jacobian), (diagonalPipeline, diagonal)] {
                guard let encoder = command.makeComputeCommandEncoder() else { throw ReferenceMetalOperatorError.commandSetupFailed }
                encoder.setComputePipelineState(pipeline)
                for (index, input) in inputs.enumerated() { encoder.setBuffer(input, offset: 0, index: index) }
                encoder.setBuffer(output, offset: 0, index: 6)
                encoder.setBytes(&parameters, length: MemoryLayout<ReferenceMetalOperatorParameters>.stride, index: 7)
                encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                encoder.endEncoding()
            }
        }
        for phase: UInt32 in count > 0 ? [0, 1] : [1] {
            guard let encoder = command.makeComputeCommandEncoder() else { throw ReferenceMetalOperatorError.commandSetupFailed }
            encoder.setComputePipelineState(dotPipeline)
            encoder.setBuffer(inputs[5], offset: 0, index: 0)
            encoder.setBuffer(jacobian, offset: 0, index: 1)
            encoder.setBuffer(blocks, offset: 0, index: 2)
            encoder.setBuffer(dot, offset: 0, index: 3)
            var reduction = SIMD4<UInt32>(bubbleCount, UInt32(blockCount), phase, 0)
            encoder.setBytes(&reduction, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
            encoder.dispatchThreadgroups(MTLSize(width: phase == 0 ? blockCount : 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: phase == 0 ? 256 : 1, height: 1, depth: 1))
            encoder.endEncoding()
        }
        // All numerical work and both reduction phases finish before any readback.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                if completed.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: ReferenceMetalOperatorError.executionFailed(completed.error?.localizedDescription ?? "Metal command failed")) }
            }
            command.commit()
        }
        try Task.checkCancellation()
        func vectors(_ buffer: MTLBuffer) -> [ReferenceVector2] {
            let pointer = buffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
            return (0..<count).map { .init(x: pointer[$0].x, y: pointer[$0].y) }
        }
        return .init(residual: vectors(residual), jacobianVector: vectors(jacobian), inverseDiagonal: vectors(diagonal),
                     dotProduct: dot.contents().load(as: Float.self))
    }

    func solvePCGForTesting(snapshot: ReferenceMetalSnapshot, endCenters: [ReferenceVector2],
                            rightHandSide: [ReferenceVector2], limit: Int) async throws -> ReferencePCGResult {
        guard !evaluationInFlight else { throw ReferenceMetalOperatorError.evaluationInFlight }
        let count = snapshot.bubbles.count
        guard endCenters.count == count, rightHandSide.count == count,
              snapshot.centers.count == count, snapshot.velocities.count == count,
              let bubbleCount = UInt32(exactly: count),
              let contactCount = UInt32(exactly: snapshot.contacts.count),
              let iterationLimit = UInt32(exactly: max(0, limit)),
              snapshot.configuration.timeStep.isFinite, snapshot.configuration.timeStep > 0
        else { throw ReferenceMetalOperatorError.invalidInput }
        evaluationInFlight = true
        defer { evaluationInFlight = false }

        let inputs = try [upload(snapshot.bubbles, name: "bubbles"),
                          upload(snapshot.centers, name: "start"),
                          upload(snapshot.velocities, name: "velocity"),
                          upload(snapshot.contacts, name: "contacts"),
                          upload(endCenters.map { SIMD2($0.x, $0.y) }, name: "end")]
        let rhs = try upload(rightHandSide.map { SIMD2($0.x, $0.y) }, name: "pcgRHS")
        let stride = MemoryLayout<SIMD2<Float>>.stride
        let solution = try buffer(name: "pcgSolution", count: count, stride: stride)
        let residual = try buffer(name: "pcgResidual", count: count, stride: stride)
        let direction = try buffer(name: "pcgDirection", count: count, stride: stride)
        let preconditioned = try buffer(name: "pcgPreconditioned", count: count, stride: stride)
        let diagonal = try buffer(name: "diagonal", count: count, stride: stride)
        let applied = try buffer(name: "jacobian", count: count, stride: stride)
        let blockCount = count / 256 + (count % 256 == 0 ? 0 : 1)
        let blocks = try buffer(name: "dotBlocks", count: blockCount, stride: MemoryLayout<Float>.stride)
        let denominator = try buffer(name: "dot", count: 1, stride: MemoryLayout<Float>.stride)
        let control = try buffer(name: "pcgControl", count: 1, stride: MemoryLayout<ReferenceMetalPCGControl>.stride)
        guard let command = commandQueue.makeCommandBuffer() else { throw ReferenceMetalOperatorError.commandSetupFailed }
        let config = snapshot.configuration
        var parameters = ReferenceMetalOperatorParameters(counts: SIMD4(bubbleCount, contactCount, 0, 0),
            physics: SIMD4(config.timeStep, config.contactStiffness, config.nonlinearStiffening, config.contactDamping),
            drag: SIMD4(config.linearDamping, 0, 0, 0))
        var pcgCounts = SIMD4<UInt32>(bubbleCount, iterationLimit, 0, 0)
        var tolerance = config.pcgTolerance

        func encodeOperator(_ pipeline: MTLComputePipelineState, output: MTLBuffer) throws {
            guard count > 0 else { return }
            guard let encoder = command.makeComputeCommandEncoder() else { throw ReferenceMetalOperatorError.commandSetupFailed }
            encoder.setComputePipelineState(pipeline)
            for (index, input) in inputs.enumerated() { encoder.setBuffer(input, offset: 0, index: index) }
            encoder.setBuffer(direction, offset: 0, index: 5)
            encoder.setBuffer(output, offset: 0, index: 6)
            encoder.setBytes(&parameters, length: MemoryLayout<ReferenceMetalOperatorParameters>.stride, index: 7)
            encoder.dispatchThreads(MTLSize(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: min(256, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            encoder.endEncoding()
        }
        func encodePCG(_ pipeline: MTLComputePipelineState, parallel: Bool = false) throws {
            guard let encoder = command.makeComputeCommandEncoder() else { throw ReferenceMetalOperatorError.commandSetupFailed }
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in [rhs, diagonal, solution, residual, preconditioned, direction, applied, denominator, control].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            encoder.setBytes(&pcgCounts, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 9)
            encoder.setBytes(&tolerance, length: MemoryLayout<Float>.stride, index: 10)
            encoder.dispatchThreads(MTLSize(width: parallel ? max(1, count) : 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: parallel ? min(256, pipeline.maxTotalThreadsPerThreadgroup) : 1, height: 1, depth: 1))
            encoder.endEncoding()
        }
        try encodeOperator(diagonalPipeline, output: diagonal)
        try encodePCG(pcgInitializePipeline)
        // CPU encodes exactly the requested maximum, independent of GPU scalars.
        // The control record freezes correction/residual/direction after stopping.
        for _ in 0..<max(0, limit) {
            try encodeOperator(jacobianPipeline, output: applied)
            for phase: UInt32 in count > 0 ? [0, 1] : [1] {
                guard let encoder = command.makeComputeCommandEncoder() else { throw ReferenceMetalOperatorError.commandSetupFailed }
                encoder.setComputePipelineState(dotPipeline)
                for (index, buffer) in [direction, applied, blocks, denominator].enumerated() {
                    encoder.setBuffer(buffer, offset: 0, index: index)
                }
                var reduction = SIMD4<UInt32>(bubbleCount, UInt32(blockCount), phase, 0)
                encoder.setBytes(&reduction, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
                encoder.dispatchThreadgroups(MTLSize(width: phase == 0 ? blockCount : 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: phase == 0 ? 256 : 1, height: 1, depth: 1))
                encoder.endEncoding()
            }
            try encodePCG(pcgAdvancePipeline)
            try encodePCG(pcgDirectionPipeline, parallel: true)
        }
        try encodePCG(pcgFinalizePipeline)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { completed in
                if completed.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: ReferenceMetalOperatorError.executionFailed(completed.error?.localizedDescription ?? "Metal command failed")) }
            }
            command.commit()
        }
        try Task.checkCancellation()
        // The CPU result has no public initializer. An empty zero-iteration solve
        // only constructs the value; every reported field comes from final GPU readback.
        var result = ReferencePCGSolver.solve(rightHandSide: [], apply: { $0 }, inverseDiagonal: [], tolerance: 0, iterationLimit: 0)
        let values = solution.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
        let status = control.contents().load(as: ReferenceMetalPCGControl.self)
        result.solution = (0..<count).map { .init(x: values[$0].x, y: values[$0].y) }
        result.iterationCount = Int(status.state.y)
        result.initialResidualNorm = status.norms.x
        result.finalResidualNorm = status.norms.y
        result.hasNonFiniteState = status.state.z != 0
        return result
    }

    private func buffer(name: String, count: Int, stride: Int) throws -> MTLBuffer {
        let length = try ReferenceMetalCapacityManager.byteLength(count: count, stride: stride, maximum: device.maxBufferLength)
        if let existing = operatorBuffers[name], existing.length >= length { return existing }
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw ReferenceMetalCapacityError.allocationFailed
        }
        operatorBuffers[name] = buffer
        return buffer
    }

    private func upload<T>(_ values: [T], name: String) throws -> MTLBuffer {
        let result = try buffer(name: name, count: values.count, stride: MemoryLayout<T>.stride)
        if !values.isEmpty { _ = values.withUnsafeBytes { memcpy(result.contents(), $0.baseAddress!, $0.count) } }
        return result
    }
}
