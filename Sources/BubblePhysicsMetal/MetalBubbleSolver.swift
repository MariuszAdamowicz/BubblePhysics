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
    private let aabbPipeline: MTLComputePipelineState
    private let pairPipeline: MTLComputePipelineState
    private let keyPipeline: MTLComputePipelineState
    private let sortPipeline: MTLComputePipelineState
    private let buildPipeline: MTLComputePipelineState

    public private(set) var lastBroadPhaseComparisonCount = 0

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
              let lbvhURL = Bundle.module.url(forResource: "LBVHKernels", withExtension: "metal"),
              let lbvhSource = try? String(contentsOf: lbvhURL),
              let lbvhLibrary = try? device.makeLibrary(source: lbvhSource, options: nil),
              let aabbFunction = lbvhLibrary.makeFunction(name: "computeBubbleAABBs"),
              let pairFunction = lbvhLibrary.makeFunction(name: "emitCandidatePairs"),
              let keyFunction = lbvhLibrary.makeFunction(name: "encodeMortonKeys"),
              let sortFunction = lbvhLibrary.makeFunction(name: "radixSortMortonKeys"),
              let buildFunction = lbvhLibrary.makeFunction(name: "buildLBVH"),
              let commandQueue = device.makeCommandQueue(),
              let predictionPipeline = try? device.makeComputePipelineState(function: predictionFunction),
              let shapePipeline = try? device.makeComputePipelineState(function: shapeFunction),
              let boundsPipeline = try? device.makeComputePipelineState(function: boundsFunction),
              let aabbPipeline = try? device.makeComputePipelineState(function: aabbFunction),
              let pairPipeline = try? device.makeComputePipelineState(function: pairFunction),
              let keyPipeline = try? device.makeComputePipelineState(function: keyFunction),
              let sortPipeline = try? device.makeComputePipelineState(function: sortFunction)
              , let buildPipeline = try? device.makeComputePipelineState(function: buildFunction)
        else { return nil }

        self.device = device
        loadedFunctionNames = ["predictParticles", "solveBubbleShape", "solveWorldBounds", "computeBubbleAABBs", "emitCandidatePairs"]
        capacityManager = MetalCapacityManager(capacities: capacities)
        self.commandQueue = commandQueue
        self.predictionPipeline = predictionPipeline
        self.shapePipeline = shapePipeline
        self.boundsPipeline = boundsPipeline
        self.aabbPipeline = aabbPipeline
        self.pairPipeline = pairPipeline
        self.keyPipeline = keyPipeline
        self.sortPipeline = sortPipeline
        self.buildPipeline = buildPipeline
    }

    public func candidatePairs(snapshot: MetalWorldSnapshot) async throws -> [MetalBubblePair] {
        let bubbleCount = snapshot.bubbleRanges.count
        guard bubbleCount > 1 else { return [] }
        let requirements = MetalBufferRequirements(pairs: bubbleCount * (bubbleCount - 1) / 2, contacts: 0, corrections: 0)
        _ = capacityManager.ensureCapacity(for: requirements)
        guard let particleBuffer = makeBuffer(snapshot.particles),
              let rangeBuffer = makeBuffer(snapshot.bubbleRanges),
              let aabbBuffer = device.makeBuffer(length: bubbleCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let keyBuffer = device.makeBuffer(length: nextPowerOfTwo(bubbleCount) * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared),
              let treeBuffer = device.makeBuffer(length: nextPowerOfTwo(bubbleCount) * 2 * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let pairBuffer = device.makeBuffer(length: max(1, capacities.pairs) * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared),
              let countBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let comparisonBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { throw MetalSolverError.bufferAllocationFailed }
        countBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        comparisonBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        var encodedCount = UInt32(bubbleCount)
        var pairCapacity = UInt32(capacities.pairs)
        guard let aabbEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        aabbEncoder.setComputePipelineState(aabbPipeline)
        aabbEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
        aabbEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
        aabbEncoder.setBuffer(aabbBuffer, offset: 0, index: 2)
        aabbEncoder.setBytes(&encodedCount, length: MemoryLayout<UInt32>.stride, index: 3)
        dispatch(aabbEncoder, pipeline: aabbPipeline, count: bubbleCount)
        aabbEncoder.endEncoding()
        let sortCount = nextPowerOfTwo(bubbleCount)
        let keyRecords = keyBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: sortCount)
        for index in bubbleCount..<sortCount { keyRecords[index] = SIMD2(UInt32.max, UInt32(index)) }
        guard let keyEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        keyEncoder.setComputePipelineState(keyPipeline)
        keyEncoder.setBuffer(aabbBuffer, offset: 0, index: 0)
        keyEncoder.setBuffer(keyBuffer, offset: 0, index: 1)
        keyEncoder.setBytes(&encodedCount, length: MemoryLayout<UInt32>.stride, index: 2)
        dispatch(keyEncoder, pipeline: keyPipeline, count: bubbleCount)
        keyEncoder.endEncoding()
        var encodedSortCount = UInt32(sortCount)
        var stage = 2
        while stage <= sortCount {
            var strideValue = stage / 2
            while strideValue > 0 {
                var encodedStage = UInt32(stage)
                var encodedStride = UInt32(strideValue)
                guard let sortEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
                sortEncoder.setComputePipelineState(sortPipeline)
                sortEncoder.setBuffer(keyBuffer, offset: 0, index: 0)
                sortEncoder.setBytes(&encodedSortCount, length: MemoryLayout<UInt32>.stride, index: 1)
                sortEncoder.setBytes(&encodedStage, length: MemoryLayout<UInt32>.stride, index: 2)
                sortEncoder.setBytes(&encodedStride, length: MemoryLayout<UInt32>.stride, index: 3)
                dispatch(sortEncoder, pipeline: sortPipeline, count: sortCount)
                sortEncoder.endEncoding()
                strideValue /= 2
            }
            stage *= 2
        }
        var leafBase = UInt32(sortCount)
        var levelStart = UInt32(sortCount)
        var levelCount = UInt32(sortCount)
        guard let leafEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        leafEncoder.setComputePipelineState(buildPipeline)
        leafEncoder.setBuffer(aabbBuffer, offset: 0, index: 0)
        leafEncoder.setBuffer(keyBuffer, offset: 0, index: 1)
        leafEncoder.setBuffer(treeBuffer, offset: 0, index: 2)
        leafEncoder.setBytes(&encodedCount, length: MemoryLayout<UInt32>.stride, index: 3)
        leafEncoder.setBytes(&leafBase, length: MemoryLayout<UInt32>.stride, index: 4)
        leafEncoder.setBytes(&levelStart, length: MemoryLayout<UInt32>.stride, index: 5)
        leafEncoder.setBytes(&levelCount, length: MemoryLayout<UInt32>.stride, index: 6)
        dispatch(leafEncoder, pipeline: buildPipeline, count: sortCount)
        leafEncoder.endEncoding()
        var parentCount = sortCount / 2
        while parentCount > 0 {
            levelStart = UInt32(parentCount)
            levelCount = UInt32(parentCount)
            guard let treeEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            treeEncoder.setComputePipelineState(buildPipeline)
            treeEncoder.setBuffer(aabbBuffer, offset: 0, index: 0)
            treeEncoder.setBuffer(keyBuffer, offset: 0, index: 1)
            treeEncoder.setBuffer(treeBuffer, offset: 0, index: 2)
            treeEncoder.setBytes(&encodedCount, length: MemoryLayout<UInt32>.stride, index: 3)
            treeEncoder.setBytes(&leafBase, length: MemoryLayout<UInt32>.stride, index: 4)
            treeEncoder.setBytes(&levelStart, length: MemoryLayout<UInt32>.stride, index: 5)
            treeEncoder.setBytes(&levelCount, length: MemoryLayout<UInt32>.stride, index: 6)
            dispatch(treeEncoder, pipeline: buildPipeline, count: parentCount)
            treeEncoder.endEncoding()
            parentCount /= 2
        }
        guard let pairEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        pairEncoder.setComputePipelineState(pairPipeline)
        pairEncoder.setBuffer(aabbBuffer, offset: 0, index: 0)
        pairEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
        pairEncoder.setBuffer(keyBuffer, offset: 0, index: 2)
        pairEncoder.setBuffer(pairBuffer, offset: 0, index: 3)
        pairEncoder.setBuffer(countBuffer, offset: 0, index: 4)
        pairEncoder.setBuffer(comparisonBuffer, offset: 0, index: 5)
        pairEncoder.setBuffer(treeBuffer, offset: 0, index: 6)
        pairEncoder.setBytes(&encodedCount, length: MemoryLayout<UInt32>.stride, index: 7)
        pairEncoder.setBytes(&pairCapacity, length: MemoryLayout<UInt32>.stride, index: 8)
        pairEncoder.setBytes(&leafBase, length: MemoryLayout<UInt32>.stride, index: 9)
        dispatch(pairEncoder, pipeline: pairPipeline, count: bubbleCount)
        pairEncoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        let count = Int(countBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        lastBroadPhaseComparisonCount = Int(comparisonBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        guard count <= capacities.pairs else { throw MetalSolverError.candidatePairOverflow }
        let records = pairBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: records, count: count)).map { MetalBubblePair(firstID: $0.x, secondID: $0.y) }.sorted()
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

    private func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result *= 2 }
        return result
    }
}

public struct MetalShapeStepResult: Equatable, Sendable {
    public let particles: [MetalParticle]
}

public enum MetalSolverError: Error {
    case bufferAllocationFailed
    case commandEncodingFailed
    case commandExecutionFailed
    case candidatePairOverflow
}
