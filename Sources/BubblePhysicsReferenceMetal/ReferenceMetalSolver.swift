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
              let pipeline = try? device.makeComputePipelineState(function: function),
              let jacobianPipeline = try? device.makeComputePipelineState(function: jacobian),
              let diagonalPipeline = try? device.makeComputePipelineState(function: diagonal),
              let dotPipeline = try? device.makeComputePipelineState(function: dot),
              dotPipeline.maxTotalThreadsPerThreadgroup >= 256,
              let commandQueue = device.makeCommandQueue()
        else { return nil }

        self.device = device
        capacityManager = ReferenceMetalCapacityManager(device: device)
        residualPipeline = pipeline
        self.jacobianPipeline = jacobianPipeline
        self.diagonalPipeline = diagonalPipeline
        self.dotPipeline = dotPipeline
        self.commandQueue = commandQueue
        loadedFunctionNames = [function.name, jacobian.name, diagonal.name, dot.name]
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
