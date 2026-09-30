import Foundation
import Metal
import BubblePhysics

public final class MetalBubbleSolver {
    public let device: MTLDevice
    public let loadedFunctionNames: Set<String>
    private let capacityManager: MetalCapacityManager
    private let commandQueue: MTLCommandQueue
    private let predictionPipeline: MTLComputePipelineState
    private let shapePipeline: MTLComputePipelineState
    private let boundsPipeline: MTLComputePipelineState

    public var isAvailable: Bool { true }
    public var capacities: MetalBufferCapacities { capacityManager.capacities }

    public init?(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        capacities: MetalBufferCapacities = .init()
    ) {
        guard let device,
              let shaderURL = Bundle.module.url(forResource: "BubblePhysicsKernels", withExtension: "metal"),
              let source = try? String(contentsOf: shaderURL),
              let library = try? device.makeLibrary(source: source, options: nil),
              let predictionFunction = library.makeFunction(name: "predictParticles"),
              let shapeFunction = library.makeFunction(name: "solveBubbleShape"),
              let boundsFunction = library.makeFunction(name: "solveWorldBounds"),
              let commandQueue = device.makeCommandQueue(),
              let predictionPipeline = try? device.makeComputePipelineState(function: predictionFunction),
              let shapePipeline = try? device.makeComputePipelineState(function: shapeFunction),
              let boundsPipeline = try? device.makeComputePipelineState(function: boundsFunction)
        else { return nil }

        self.device = device
        loadedFunctionNames = ["predictParticles", "solveBubbleShape", "solveWorldBounds"]
        capacityManager = MetalCapacityManager(capacities: capacities)
        self.commandQueue = commandQueue
        self.predictionPipeline = predictionPipeline
        self.shapePipeline = shapePipeline
        self.boundsPipeline = boundsPipeline
    }

    public func step(snapshot: MetalWorldSnapshot, commands: [WorldCommand]) async throws -> MetalStepTelemetry {
        let bubbleCount = snapshot.bubbleRanges.count
        let reservedPairCount = bubbleCount * max(0, bubbleCount - 1) / 2
        let requirements = MetalBufferRequirements(
            pairs: reservedPairCount,
            contacts: reservedPairCount,
            corrections: reservedPairCount * 2
        )
        let didRetry = capacityManager.ensureCapacity(for: requirements)
        _ = commands
        return MetalStepTelemetry(
            candidatePairCount: reservedPairCount,
            contactCount: 0,
            correctionCount: 0,
            didOverflow: false,
            didRetry: didRetry
        )
    }

    public func solveShape(
        snapshot: MetalWorldSnapshot,
        gravity: Vector2,
        bounds: AABB?,
        configuration: WorldConfiguration
    ) async throws -> MetalShapeStepResult {
        guard !snapshot.particles.isEmpty else { return MetalShapeStepResult(particles: []) }
        guard let particleBuffer = makeBuffer(snapshot.particles),
              let rangeBuffer = makeBuffer(snapshot.bubbleRanges),
              let distanceBuffer = makeBuffer(snapshot.distanceConstraints, minimumCount: 1),
              let areaBuffer = makeBuffer(snapshot.areaConstraints, minimumCount: 1),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { throw MetalSolverError.bufferAllocationFailed }

        var particleCount = UInt32(snapshot.particles.count)
        var bubbleCount = UInt32(snapshot.bubbleRanges.count)
        var gravityValue = SIMD2<Float>(gravity.x, gravity.y)
        var timeStep = configuration.fixedTimeStep
        var damping = configuration.linearDamping

        guard let predictionEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalSolverError.commandEncodingFailed
        }
        predictionEncoder.setComputePipelineState(predictionPipeline)
        predictionEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
        predictionEncoder.setBytes(&particleCount, length: MemoryLayout<UInt32>.stride, index: 1)
        predictionEncoder.setBytes(&gravityValue, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
        predictionEncoder.setBytes(&timeStep, length: MemoryLayout<Float>.stride, index: 3)
        predictionEncoder.setBytes(&damping, length: MemoryLayout<Float>.stride, index: 4)
        dispatch(predictionEncoder, pipeline: predictionPipeline, count: snapshot.particles.count)
        predictionEncoder.endEncoding()

        var boundsMinimum = SIMD2<Float>(bounds?.minimum.x ?? -.infinity, bounds?.minimum.y ?? -.infinity)
        var boundsMaximum = SIMD2<Float>(bounds?.maximum.x ?? .infinity, bounds?.maximum.y ?? .infinity)
        for _ in 0..<configuration.solverIterations {
            guard let shapeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MetalSolverError.commandEncodingFailed
            }
            shapeEncoder.setComputePipelineState(shapePipeline)
            shapeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            shapeEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
            shapeEncoder.setBuffer(distanceBuffer, offset: 0, index: 2)
            shapeEncoder.setBuffer(areaBuffer, offset: 0, index: 3)
            shapeEncoder.setBytes(&bubbleCount, length: MemoryLayout<UInt32>.stride, index: 4)
            shapeEncoder.setBytes(&timeStep, length: MemoryLayout<Float>.stride, index: 5)
            dispatch(shapeEncoder, pipeline: shapePipeline, count: snapshot.bubbleRanges.count)
            shapeEncoder.endEncoding()

            guard let boundsEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MetalSolverError.commandEncodingFailed
            }
            boundsEncoder.setComputePipelineState(boundsPipeline)
            boundsEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            boundsEncoder.setBytes(&particleCount, length: MemoryLayout<UInt32>.stride, index: 1)
            boundsEncoder.setBytes(&boundsMinimum, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            boundsEncoder.setBytes(&boundsMaximum, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
            dispatch(boundsEncoder, pipeline: boundsPipeline, count: snapshot.particles.count)
            boundsEncoder.endEncoding()
        }

        commandBuffer.commit()
        await commandBuffer.completed()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        let result = particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: snapshot.particles.count)
        return MetalShapeStepResult(particles: Array(UnsafeBufferPointer(start: result, count: snapshot.particles.count)))
    }

    private func makeBuffer<Element>(_ values: [Element], minimumCount: Int = 0) -> MTLBuffer? {
        let count = max(values.count, minimumCount)
        let byteCount = max(1, count * MemoryLayout<Element>.stride)
        if values.isEmpty {
            return device.makeBuffer(length: byteCount, options: .storageModeShared)
        }
        return values.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: byteCount, options: .storageModeShared)
        }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, count: Int) {
        guard count > 0 else { return }
        let width = min(64, pipeline.maxTotalThreadsPerThreadgroup)
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }
}

public struct MetalShapeStepResult: Equatable, Sendable {
    public let particles: [MetalParticle]
}

public enum MetalSolverError: Error {
    case bufferAllocationFailed
    case commandEncodingFailed
    case commandExecutionFailed
}
