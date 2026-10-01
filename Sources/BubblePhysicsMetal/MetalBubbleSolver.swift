import Foundation
import Metal
import BubblePhysics

public enum MetalShaderLibraryOrigin: Equatable, Sendable {
    case compiledBundle
    case runtimeSource
}

private struct ShaderLibraries {
    let shape: MTLLibrary
    let lbvh: MTLLibrary
    let contact: MTLLibrary
    let polygon: MTLLibrary
    let origin: MetalShaderLibraryOrigin
}

public final class MetalBubbleSolver {
    public let device: MTLDevice
    public let loadedFunctionNames: Set<String>
    public let shaderLibraryOrigin: MetalShaderLibraryOrigin
    private let capacityManager: MetalCapacityManager
    private let commandQueue: MTLCommandQueue
    private let predictionPipeline: MTLComputePipelineState
    private let shapePipeline: MTLComputePipelineState
    private let boundsPipeline: MTLComputePipelineState
    private let aabbPipeline: MTLComputePipelineState
    private let pairPipeline: MTLComputePipelineState
    private let keyPipeline: MTLComputePipelineState
    private let sortPipeline: MTLComputePipelineState
    private let threadgroupSortPipeline: MTLComputePipelineState
    private let buildPipeline: MTLComputePipelineState
    private let reductionPipeline: MTLComputePipelineState
    private let contactPipeline: MTLComputePipelineState
    private let applyCorrectionPipeline: MTLComputePipelineState
    private let correctionSortPipeline: MTLComputePipelineState
    private let correctionGatherPipeline: MTLComputePipelineState
    private let gatheredApplyPipeline: MTLComputePipelineState
    private let neighborCountPipeline: MTLComputePipelineState
    private let neighborPrefixPipeline: MTLComputePipelineState
    private let neighborWritePipeline: MTLComputePipelineState
    private let adjacencyContactPipeline: MTLComputePipelineState
    private let polygonPipeline: MTLComputePipelineState
    private let grabPipeline: MTLComputePipelineState
    private var cachedContactPreparation: ContactPreparation?

    public private(set) var lastBroadPhaseComparisonCount = 0
    public private(set) var lastBroadPhaseCommandPassCount = 0
    public private(set) var contactPreparationBuildCount = 0

    public var isAvailable: Bool { true }
    public var capacities: MetalBufferCapacities { capacityManager.capacities }

    public init?(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        capacities: MetalBufferCapacities = .init()
    ) {
        guard let device, let libraries = Self.loadShaderLibraries(device: device) else { return nil }
        let library = libraries.shape
        let lbvhLibrary = libraries.lbvh
        let contactLibrary = libraries.contact
        let polygonLibrary = libraries.polygon
        guard
              let predictionFunction = library.makeFunction(name: "predictParticles"),
              let shapeFunction = library.makeFunction(name: "solveBubbleShape"),
              let boundsFunction = library.makeFunction(name: "solveWorldBounds"),
              let aabbFunction = lbvhLibrary.makeFunction(name: "computeBubbleAABBs"),
              let pairFunction = lbvhLibrary.makeFunction(name: "emitCandidatePairs"),
              let keyFunction = lbvhLibrary.makeFunction(name: "encodeMortonKeys"),
              let sortFunction = lbvhLibrary.makeFunction(name: "radixSortMortonKeys"),
              let threadgroupSortFunction = lbvhLibrary.makeFunction(name: "sortMortonKeysInThreadgroup"),
              let buildFunction = lbvhLibrary.makeFunction(name: "buildLBVH"),
              let reductionFunction = contactLibrary.makeFunction(name: "reduceCorrections"),
              let contactFunction = contactLibrary.makeFunction(name: "generateBubbleContacts"),
              let applyCorrectionFunction = contactLibrary.makeFunction(name: "applyCorrections"),
              let correctionSortFunction = contactLibrary.makeFunction(name: "sortCorrectionsByParticle"),
              let correctionGatherFunction = contactLibrary.makeFunction(name: "gatherCorrections"),
              let gatheredApplyFunction = contactLibrary.makeFunction(name: "applyGatheredCorrections"),
              let neighborCountFunction = contactLibrary.makeFunction(name: "countBubbleNeighbors"),
              let neighborPrefixFunction = contactLibrary.makeFunction(name: "prefixBubbleNeighbors"),
              let neighborWriteFunction = contactLibrary.makeFunction(name: "writeBubbleNeighbors"),
              let adjacencyContactFunction = contactLibrary.makeFunction(name: "generateAdjacencyCorrections"),
              let polygonFunction = polygonLibrary.makeFunction(name: "generatePolygonContacts"),
              let grabFunction = polygonLibrary.makeFunction(name: "applyGrabConstraint"),
              let commandQueue = device.makeCommandQueue(),
              let predictionPipeline = try? device.makeComputePipelineState(function: predictionFunction),
              let shapePipeline = try? device.makeComputePipelineState(function: shapeFunction),
              let boundsPipeline = try? device.makeComputePipelineState(function: boundsFunction),
              let aabbPipeline = try? device.makeComputePipelineState(function: aabbFunction),
              let pairPipeline = try? device.makeComputePipelineState(function: pairFunction),
              let keyPipeline = try? device.makeComputePipelineState(function: keyFunction),
              let sortPipeline = try? device.makeComputePipelineState(function: sortFunction)
              , let threadgroupSortPipeline = try? device.makeComputePipelineState(function: threadgroupSortFunction)
              , let buildPipeline = try? device.makeComputePipelineState(function: buildFunction),
              let reductionPipeline = try? device.makeComputePipelineState(function: reductionFunction),
              let contactPipeline = try? device.makeComputePipelineState(function: contactFunction),
              let applyCorrectionPipeline = try? device.makeComputePipelineState(function: applyCorrectionFunction)
              , let correctionSortPipeline = try? device.makeComputePipelineState(function: correctionSortFunction)
              , let correctionGatherPipeline = try? device.makeComputePipelineState(function: correctionGatherFunction)
              , let gatheredApplyPipeline = try? device.makeComputePipelineState(function: gatheredApplyFunction)
              , let neighborCountPipeline = try? device.makeComputePipelineState(function: neighborCountFunction)
              , let neighborPrefixPipeline = try? device.makeComputePipelineState(function: neighborPrefixFunction)
              , let neighborWritePipeline = try? device.makeComputePipelineState(function: neighborWriteFunction)
              , let adjacencyContactPipeline = try? device.makeComputePipelineState(function: adjacencyContactFunction)
              , let polygonPipeline = try? device.makeComputePipelineState(function: polygonFunction),
              let grabPipeline = try? device.makeComputePipelineState(function: grabFunction)
        else { return nil }

        self.device = device
        shaderLibraryOrigin = libraries.origin
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
        self.threadgroupSortPipeline = threadgroupSortPipeline
        self.buildPipeline = buildPipeline
        self.reductionPipeline = reductionPipeline
        self.contactPipeline = contactPipeline
        self.applyCorrectionPipeline = applyCorrectionPipeline
        self.correctionSortPipeline = correctionSortPipeline
        self.correctionGatherPipeline = correctionGatherPipeline
        self.gatheredApplyPipeline = gatheredApplyPipeline
        self.neighborCountPipeline = neighborCountPipeline
        self.neighborPrefixPipeline = neighborPrefixPipeline
        self.neighborWritePipeline = neighborWritePipeline
        self.adjacencyContactPipeline = adjacencyContactPipeline
        self.polygonPipeline = polygonPipeline
        self.grabPipeline = grabPipeline
    }

    private static func loadShaderLibraries(device: MTLDevice) -> ShaderLibraries? {
        if let compiled = try? device.makeDefaultLibrary(bundle: Bundle.module) {
            return ShaderLibraries(shape: compiled, lbvh: compiled, contact: compiled, polygon: compiled, origin: .compiledBundle)
        }
        func sourceLibrary(_ name: String) -> MTLLibrary? {
            guard let url = Bundle.module.url(forResource: name, withExtension: "metal"),
                  let source = try? String(contentsOf: url)
            else { return nil }
            return try? device.makeLibrary(source: source, options: nil)
        }
        guard let shape = sourceLibrary("BubblePhysicsKernels"),
              let lbvh = sourceLibrary("LBVHKernels"),
              let contact = sourceLibrary("ContactKernels"),
              let polygon = sourceLibrary("PolygonKernels")
        else { return nil }
        return ShaderLibraries(shape: shape, lbvh: lbvh, contact: contact, polygon: polygon, origin: .runtimeSource)
    }

    public func candidatePairs(snapshot: MetalWorldSnapshot) async throws -> [MetalBubblePair] {
        let indices = try await candidatePairIndices(snapshot: snapshot)
        return indices.map { pair in
            MetalBubblePair(
                firstID: snapshot.bubbleRanges[Int(pair.x)].id,
                secondID: snapshot.bubbleRanges[Int(pair.y)].id
            )
        }.sorted()
    }

    private func candidatePairIndices(snapshot: MetalWorldSnapshot) async throws -> [SIMD2<UInt32>] {
        let bubbleCount = snapshot.bubbleRanges.count
        guard bubbleCount > 1 else { return [] }
        let requirements = MetalBufferRequirements(pairs: bubbleCount * (bubbleCount - 1) / 2, contacts: 0, corrections: 0)
        _ = capacityManager.ensureCapacity(for: requirements)
        guard let particleBuffer = makeBuffer(snapshot.particles),
              let rangeBuffer = makeBuffer(snapshot.bubbleRanges),
              let aabbBuffer = device.makeBuffer(length: bubbleCount * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let keyBuffer = device.makeBuffer(length: nextPowerOfTwo(bubbleCount) * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared),
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
        var sortPassCount = 0
        let sortMemoryLength = sortCount * MemoryLayout<SIMD2<UInt32>>.stride
        if sortMemoryLength <= device.maxThreadgroupMemoryLength {
            guard let sortEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            sortEncoder.setComputePipelineState(threadgroupSortPipeline)
            sortEncoder.setBuffer(keyBuffer, offset: 0, index: 0)
            sortEncoder.setBytes(&encodedSortCount, length: MemoryLayout<UInt32>.stride, index: 1)
            sortEncoder.setThreadgroupMemoryLength(sortMemoryLength, index: 0)
            let threadCount = min(sortCount, threadgroupSortPipeline.maxTotalThreadsPerThreadgroup)
            sortEncoder.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: threadCount, height: 1, depth: 1)
            )
            sortEncoder.endEncoding()
            sortPassCount = 1
        } else {
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
                    sortPassCount += 1
                    strideValue /= 2
                }
                stage *= 2
            }
        }
        guard let pairEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        pairEncoder.setComputePipelineState(pairPipeline)
        pairEncoder.setBuffer(aabbBuffer, offset: 0, index: 0)
        pairEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
        pairEncoder.setBuffer(keyBuffer, offset: 0, index: 2)
        pairEncoder.setBuffer(pairBuffer, offset: 0, index: 3)
        pairEncoder.setBuffer(countBuffer, offset: 0, index: 4)
        pairEncoder.setBuffer(comparisonBuffer, offset: 0, index: 5)
        pairEncoder.setBytes(&encodedCount, length: MemoryLayout<UInt32>.stride, index: 6)
        pairEncoder.setBytes(&pairCapacity, length: MemoryLayout<UInt32>.stride, index: 7)
        dispatch(pairEncoder, pipeline: pairPipeline, count: bubbleCount)
        pairEncoder.endEncoding()
        commandBuffer.commit()
        await commandBuffer.completed()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        let count = Int(countBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        lastBroadPhaseComparisonCount = Int(comparisonBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        lastBroadPhaseCommandPassCount = 3 + sortPassCount
        guard count <= capacities.pairs else { throw MetalSolverError.candidatePairOverflow }
        let records = pairBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: count)
        return Array(UnsafeBufferPointer(start: records, count: count)).sorted {
            $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x
        }
    }

    public func reduceCorrectionsForTesting(_ corrections: [MetalCorrection]) async throws -> [Int: SIMD2<Float>] {
        let particleCount = Int((corrections.map(\.particleIndex).max() ?? 0) + 1)
        guard particleCount > 0, let correctionBuffer = makeBuffer(corrections), let resultBuffer = device.makeBuffer(length: particleCount * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared), let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { return [:] }
        var count = UInt32(corrections.count); var particles = UInt32(particleCount)
        encoder.setComputePipelineState(reductionPipeline); encoder.setBuffer(correctionBuffer, offset: 0, index: 0); encoder.setBuffer(resultBuffer, offset: 0, index: 1); encoder.setBytes(&count, length: 4, index: 2); encoder.setBytes(&particles, length: 4, index: 3); dispatch(encoder, pipeline: reductionPipeline, count: particleCount); encoder.endEncoding(); commandBuffer.commit(); await commandBuffer.completed()
        let values = resultBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: particleCount)
        return Dictionary(uniqueKeysWithValues: (0..<particleCount).map { ($0, values[$0]) })
    }

    public func solveContacts(snapshot: MetalWorldSnapshot, configuration: WorldConfiguration) async throws -> MetalContactStepResult {
        try await solveContactPipeline(
            snapshot: snapshot,
            gravity: nil,
            bounds: nil,
            configuration: configuration
        )
    }

    public func solveFrame(
        snapshot: MetalWorldSnapshot,
        gravity: Vector2,
        bounds: AABB?,
        configuration: WorldConfiguration
    ) async throws -> MetalContactStepResult {
        try await solveContactPipeline(
            snapshot: snapshot,
            gravity: gravity,
            bounds: bounds,
            configuration: configuration
        )
    }

    private func solveContactPipeline(
        snapshot: MetalWorldSnapshot,
        gravity: Vector2?,
        bounds: AABB?,
        configuration: WorldConfiguration
    ) async throws -> MetalContactStepResult {
        let solveStart = ProcessInfo.processInfo.systemUptime
        let bubbleCountValue = snapshot.bubbleRanges.count
        guard bubbleCountValue > 1 else {
            return contactResult(
                particles: snapshot.particles,
                ranges: snapshot.bubbleRanges,
                candidatePairCount: 0,
                commandPassCount: 0,
                broadPhaseMilliseconds: 0,
                preparationMilliseconds: 0,
                solveMilliseconds: 0
            )
        }
        _ = capacityManager.ensureCapacity(for: MetalBufferRequirements(
            pairs: bubbleCountValue * (bubbleCountValue - 1) / 2,
            contacts: 0,
            corrections: 0
        ))
        let pairCapacityValue = max(1, capacities.pairs)
        let sortCount = nextPowerOfTwo(bubbleCountValue)
        guard let particleBuffer = makeBuffer(snapshot.particles),
              let rangeBuffer = makeBuffer(snapshot.bubbleRanges),
              let aabbBuffer = device.makeBuffer(length: bubbleCountValue * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
              let keyBuffer = device.makeBuffer(length: sortCount * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared),
              let pairBuffer = device.makeBuffer(length: pairCapacityValue * MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared),
              let pairCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let comparisonBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let neighborCountBuffer = device.makeBuffer(length: bubbleCountValue * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let neighborOffsetBuffer = device.makeBuffer(length: (bubbleCountValue + 1) * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let neighborCursorBuffer = device.makeBuffer(length: bubbleCountValue * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let neighborBuffer = device.makeBuffer(length: pairCapacityValue * 2 * MemoryLayout<UInt32>.stride, options: .storageModeShared),
              let deltaBuffer = device.makeBuffer(length: snapshot.particles.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
              let distanceBuffer = makeBuffer(snapshot.distanceConstraints, minimumCount: 1),
              let areaBuffer = makeBuffer(snapshot.areaConstraints, minimumCount: 1),
              let commandBuffer = commandQueue.makeCommandBuffer()
        else { throw MetalSolverError.bufferAllocationFailed }
        pairCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        comparisonBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        neighborCountBuffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: neighborCountBuffer.length)
        neighborCursorBuffer.contents().initializeMemory(as: UInt8.self, repeating: 0, count: neighborCursorBuffer.length)
        let keyRecords = keyBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: sortCount)
        for index in bubbleCountValue..<sortCount { keyRecords[index] = SIMD2(UInt32.max, UInt32(index)) }
        var pairCapacity = UInt32(pairCapacityValue)
        var particleCount = UInt32(snapshot.particles.count)
        var bubbleCount = UInt32(snapshot.bubbleRanges.count)
        var timeStep = configuration.fixedTimeStep

        if let gravity {
            var gravityValue = SIMD2<Float>(gravity.x, gravity.y)
            var damping = configuration.linearDamping
            guard let predictionEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            predictionEncoder.setComputePipelineState(predictionPipeline)
            predictionEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            predictionEncoder.setBytes(&particleCount, length: 4, index: 1)
            predictionEncoder.setBytes(&gravityValue, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            predictionEncoder.setBytes(&timeStep, length: 4, index: 3)
            predictionEncoder.setBytes(&damping, length: 4, index: 4)
            dispatch(predictionEncoder, pipeline: predictionPipeline, count: snapshot.particles.count)
            predictionEncoder.endEncoding()
        }

        guard let aabbEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        aabbEncoder.setComputePipelineState(aabbPipeline)
        aabbEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
        aabbEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
        aabbEncoder.setBuffer(aabbBuffer, offset: 0, index: 2)
        aabbEncoder.setBytes(&bubbleCount, length: 4, index: 3)
        dispatch(aabbEncoder, pipeline: aabbPipeline, count: bubbleCountValue)
        aabbEncoder.endEncoding()

        guard let keyEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        keyEncoder.setComputePipelineState(keyPipeline)
        keyEncoder.setBuffer(aabbBuffer, offset: 0, index: 0)
        keyEncoder.setBuffer(keyBuffer, offset: 0, index: 1)
        keyEncoder.setBytes(&bubbleCount, length: 4, index: 2)
        dispatch(keyEncoder, pipeline: keyPipeline, count: bubbleCountValue)
        keyEncoder.endEncoding()

        var encodedSortCount = UInt32(sortCount)
        var broadPhaseSortPassCount = 0
        let sortMemoryLength = sortCount * MemoryLayout<SIMD2<UInt32>>.stride
        if sortMemoryLength <= device.maxThreadgroupMemoryLength {
            guard let sortEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            sortEncoder.setComputePipelineState(threadgroupSortPipeline)
            sortEncoder.setBuffer(keyBuffer, offset: 0, index: 0)
            sortEncoder.setBytes(&encodedSortCount, length: 4, index: 1)
            sortEncoder.setThreadgroupMemoryLength(sortMemoryLength, index: 0)
            sortEncoder.dispatchThreadgroups(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(
                    width: min(sortCount, threadgroupSortPipeline.maxTotalThreadsPerThreadgroup),
                    height: 1,
                    depth: 1
                )
            )
            sortEncoder.endEncoding()
            broadPhaseSortPassCount = 1
        } else {
            var stage = 2
            while stage <= sortCount {
                var strideValue = stage / 2
                while strideValue > 0 {
                    var encodedStage = UInt32(stage)
                    var encodedStride = UInt32(strideValue)
                    guard let sortEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
                    sortEncoder.setComputePipelineState(sortPipeline)
                    sortEncoder.setBuffer(keyBuffer, offset: 0, index: 0)
                    sortEncoder.setBytes(&encodedSortCount, length: 4, index: 1)
                    sortEncoder.setBytes(&encodedStage, length: 4, index: 2)
                    sortEncoder.setBytes(&encodedStride, length: 4, index: 3)
                    dispatch(sortEncoder, pipeline: sortPipeline, count: sortCount)
                    sortEncoder.endEncoding()
                    broadPhaseSortPassCount += 1
                    strideValue /= 2
                }
                stage *= 2
            }
        }

        guard let pairEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        pairEncoder.setComputePipelineState(pairPipeline)
        pairEncoder.setBuffer(aabbBuffer, offset: 0, index: 0)
        pairEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
        pairEncoder.setBuffer(keyBuffer, offset: 0, index: 2)
        pairEncoder.setBuffer(pairBuffer, offset: 0, index: 3)
        pairEncoder.setBuffer(pairCountBuffer, offset: 0, index: 4)
        pairEncoder.setBuffer(comparisonBuffer, offset: 0, index: 5)
        pairEncoder.setBytes(&bubbleCount, length: 4, index: 6)
        pairEncoder.setBytes(&pairCapacity, length: 4, index: 7)
        dispatch(pairEncoder, pipeline: pairPipeline, count: bubbleCountValue)
        pairEncoder.endEncoding()

        guard let countEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        countEncoder.setComputePipelineState(neighborCountPipeline)
        countEncoder.setBuffer(pairBuffer, offset: 0, index: 0)
        countEncoder.setBuffer(pairCountBuffer, offset: 0, index: 1)
        countEncoder.setBuffer(neighborCountBuffer, offset: 0, index: 2)
        countEncoder.setBytes(&pairCapacity, length: 4, index: 3)
        dispatch(countEncoder, pipeline: neighborCountPipeline, count: pairCapacityValue)
        countEncoder.endEncoding()

        guard let prefixEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        prefixEncoder.setComputePipelineState(neighborPrefixPipeline)
        prefixEncoder.setBuffer(neighborCountBuffer, offset: 0, index: 0)
        prefixEncoder.setBuffer(neighborOffsetBuffer, offset: 0, index: 1)
        prefixEncoder.setBuffer(neighborCursorBuffer, offset: 0, index: 2)
        prefixEncoder.setBytes(&bubbleCount, length: 4, index: 3)
        dispatch(prefixEncoder, pipeline: neighborPrefixPipeline, count: 1)
        prefixEncoder.endEncoding()

        guard let neighborEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        neighborEncoder.setComputePipelineState(neighborWritePipeline)
        neighborEncoder.setBuffer(pairBuffer, offset: 0, index: 0)
        neighborEncoder.setBuffer(pairCountBuffer, offset: 0, index: 1)
        neighborEncoder.setBuffer(neighborCursorBuffer, offset: 0, index: 2)
        neighborEncoder.setBuffer(neighborBuffer, offset: 0, index: 3)
        neighborEncoder.setBytes(&pairCapacity, length: 4, index: 4)
        dispatch(neighborEncoder, pipeline: neighborWritePipeline, count: pairCapacityValue)
        neighborEncoder.endEncoding()

        var boundsMinimum = SIMD2<Float>(bounds?.minimum.x ?? -.infinity, bounds?.minimum.y ?? -.infinity)
        var boundsMaximum = SIMD2<Float>(bounds?.maximum.x ?? .infinity, bounds?.maximum.y ?? .infinity)
        for _ in 0..<configuration.solverIterations {
            guard let contactEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            contactEncoder.setComputePipelineState(adjacencyContactPipeline)
            contactEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            contactEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
            contactEncoder.setBuffer(neighborOffsetBuffer, offset: 0, index: 2)
            contactEncoder.setBuffer(neighborBuffer, offset: 0, index: 3)
            contactEncoder.setBuffer(deltaBuffer, offset: 0, index: 4)
            contactEncoder.setBytes(&particleCount, length: 4, index: 5)
            dispatch(contactEncoder, pipeline: adjacencyContactPipeline, count: snapshot.particles.count)
            contactEncoder.endEncoding()
            guard let applyEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            applyEncoder.setComputePipelineState(applyCorrectionPipeline)
            applyEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            applyEncoder.setBuffer(deltaBuffer, offset: 0, index: 1)
            applyEncoder.setBytes(&particleCount, length: 4, index: 2)
            dispatch(applyEncoder, pipeline: applyCorrectionPipeline, count: snapshot.particles.count)
            applyEncoder.endEncoding()
            guard let shapeEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            shapeEncoder.setComputePipelineState(shapePipeline)
            shapeEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
            shapeEncoder.setBuffer(rangeBuffer, offset: 0, index: 1)
            shapeEncoder.setBuffer(distanceBuffer, offset: 0, index: 2)
            shapeEncoder.setBuffer(areaBuffer, offset: 0, index: 3)
            shapeEncoder.setBytes(&bubbleCount, length: 4, index: 4)
            shapeEncoder.setBytes(&timeStep, length: 4, index: 5)
            dispatch(shapeEncoder, pipeline: shapePipeline, count: snapshot.bubbleRanges.count)
            shapeEncoder.endEncoding()
            if bounds != nil {
                guard let boundsEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
                boundsEncoder.setComputePipelineState(boundsPipeline)
                boundsEncoder.setBuffer(particleBuffer, offset: 0, index: 0)
                boundsEncoder.setBytes(&particleCount, length: 4, index: 1)
                boundsEncoder.setBytes(&boundsMinimum, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
                boundsEncoder.setBytes(&boundsMaximum, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
                dispatch(boundsEncoder, pipeline: boundsPipeline, count: snapshot.particles.count)
                boundsEncoder.endEncoding()
            }
        }
        commandBuffer.commit(); await commandBuffer.completed()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        let solveMilliseconds = (ProcessInfo.processInfo.systemUptime - solveStart) * 1_000
        let candidatePairCount = Int(pairCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        guard candidatePairCount <= pairCapacityValue else { throw MetalSolverError.candidatePairOverflow }
        lastBroadPhaseComparisonCount = Int(comparisonBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        lastBroadPhaseCommandPassCount = 3 + broadPhaseSortPassCount
        let pointer = particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: snapshot.particles.count)
        return contactResult(
            particles: Array(UnsafeBufferPointer(start: pointer, count: snapshot.particles.count)),
            ranges: snapshot.bubbleRanges,
            candidatePairCount: candidatePairCount,
            commandPassCount: configuration.solverIterations * (bounds == nil ? 3 : 4) + (gravity == nil ? 0 : 1),
            broadPhaseMilliseconds: 0,
            preparationMilliseconds: 0,
            solveMilliseconds: solveMilliseconds
        )
    }

    func encodeSessionFrame(
        snapshot: MetalWorldSnapshot,
        input: MetalFrameInput,
        buffers: MetalSessionBuffers,
        commandBuffer: MTLCommandBuffer
    ) throws {
        let particleCountValue = snapshot.particles.count
        let bubbleCountValue = snapshot.bubbleRanges.count
        guard particleCountValue > 0, bubbleCountValue > 0 else { return }

        buffers.pairCount.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        buffers.comparisons.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        memset(buffers.neighborCounts.contents(), 0, buffers.neighborCounts.length)
        memset(buffers.neighborCursors.contents(), 0, buffers.neighborCursors.length)
        let keyRecords = buffers.keys.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: buffers.sortCapacity)
        for index in bubbleCountValue..<buffers.sortCapacity { keyRecords[index] = SIMD2(UInt32.max, UInt32(index)) }

        var particleCount = UInt32(particleCountValue)
        var bubbleCount = UInt32(bubbleCountValue)
        var pairCapacity = UInt32(buffers.pairCapacity)
        let configuration = input.configuration ?? snapshot.configuration
        var timeStep = configuration.fixedTimeStep

        if let gravity = input.gravity {
            var value = SIMD2<Float>(gravity.x, gravity.y)
            var damping = configuration.linearDamping
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            encoder.setComputePipelineState(predictionPipeline); encoder.setBuffer(buffers.particle, offset: 0, index: 0)
            encoder.setBytes(&particleCount, length: 4, index: 1); encoder.setBytes(&value, length: MemoryLayout<SIMD2<Float>>.stride, index: 2)
            encoder.setBytes(&timeStep, length: 4, index: 3); encoder.setBytes(&damping, length: 4, index: 4)
            dispatch(encoder, pipeline: predictionPipeline, count: particleCountValue); encoder.endEncoding()
        }

        guard let aabb = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        aabb.setComputePipelineState(aabbPipeline); aabb.setBuffer(buffers.particle, offset: 0, index: 0)
        aabb.setBuffer(buffers.ranges, offset: 0, index: 1); aabb.setBuffer(buffers.aabb, offset: 0, index: 2)
        aabb.setBytes(&bubbleCount, length: 4, index: 3); dispatch(aabb, pipeline: aabbPipeline, count: bubbleCountValue); aabb.endEncoding()

        guard let keys = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        keys.setComputePipelineState(keyPipeline); keys.setBuffer(buffers.aabb, offset: 0, index: 0)
        keys.setBuffer(buffers.keys, offset: 0, index: 1); keys.setBytes(&bubbleCount, length: 4, index: 2)
        dispatch(keys, pipeline: keyPipeline, count: bubbleCountValue); keys.endEncoding()

        var sortCount = UInt32(buffers.sortCapacity)
        let sortMemoryLength = buffers.sortCapacity * MemoryLayout<SIMD2<UInt32>>.stride
        if sortMemoryLength <= device.maxThreadgroupMemoryLength {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            encoder.setComputePipelineState(threadgroupSortPipeline); encoder.setBuffer(buffers.keys, offset: 0, index: 0)
            encoder.setBytes(&sortCount, length: 4, index: 1); encoder.setThreadgroupMemoryLength(sortMemoryLength, index: 0)
            encoder.dispatchThreadgroups(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: min(buffers.sortCapacity, threadgroupSortPipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            encoder.endEncoding()
        } else {
            var stage = 2
            while stage <= buffers.sortCapacity {
                var strideValue = stage / 2
                while strideValue > 0 {
                    var encodedStage = UInt32(stage), encodedStride = UInt32(strideValue)
                    guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
                    encoder.setComputePipelineState(sortPipeline); encoder.setBuffer(buffers.keys, offset: 0, index: 0)
                    encoder.setBytes(&sortCount, length: 4, index: 1); encoder.setBytes(&encodedStage, length: 4, index: 2); encoder.setBytes(&encodedStride, length: 4, index: 3)
                    dispatch(encoder, pipeline: sortPipeline, count: buffers.sortCapacity); encoder.endEncoding(); strideValue /= 2
                }
                stage *= 2
            }
        }

        guard let pairs = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        pairs.setComputePipelineState(pairPipeline); pairs.setBuffer(buffers.aabb, offset: 0, index: 0); pairs.setBuffer(buffers.ranges, offset: 0, index: 1)
        pairs.setBuffer(buffers.keys, offset: 0, index: 2); pairs.setBuffer(buffers.pairs, offset: 0, index: 3); pairs.setBuffer(buffers.pairCount, offset: 0, index: 4)
        pairs.setBuffer(buffers.comparisons, offset: 0, index: 5); pairs.setBytes(&bubbleCount, length: 4, index: 6); pairs.setBytes(&pairCapacity, length: 4, index: 7)
        dispatch(pairs, pipeline: pairPipeline, count: bubbleCountValue); pairs.endEncoding()

        guard let counts = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        counts.setComputePipelineState(neighborCountPipeline); counts.setBuffer(buffers.pairs, offset: 0, index: 0); counts.setBuffer(buffers.pairCount, offset: 0, index: 1)
        counts.setBuffer(buffers.neighborCounts, offset: 0, index: 2); counts.setBytes(&pairCapacity, length: 4, index: 3)
        dispatch(counts, pipeline: neighborCountPipeline, count: buffers.pairCapacity); counts.endEncoding()

        guard let prefix = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        prefix.setComputePipelineState(neighborPrefixPipeline); prefix.setBuffer(buffers.neighborCounts, offset: 0, index: 0)
        prefix.setBuffer(buffers.neighborOffsets, offset: 0, index: 1); prefix.setBuffer(buffers.neighborCursors, offset: 0, index: 2); prefix.setBytes(&bubbleCount, length: 4, index: 3)
        dispatch(prefix, pipeline: neighborPrefixPipeline, count: 1); prefix.endEncoding()

        guard let neighbors = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        neighbors.setComputePipelineState(neighborWritePipeline); neighbors.setBuffer(buffers.pairs, offset: 0, index: 0); neighbors.setBuffer(buffers.pairCount, offset: 0, index: 1)
        neighbors.setBuffer(buffers.neighborCursors, offset: 0, index: 2); neighbors.setBuffer(buffers.neighbors, offset: 0, index: 3); neighbors.setBytes(&pairCapacity, length: 4, index: 4)
        dispatch(neighbors, pipeline: neighborWritePipeline, count: buffers.pairCapacity); neighbors.endEncoding()

        var boundsMinimum = SIMD2<Float>(input.bounds?.minimum.x ?? -.infinity, input.bounds?.minimum.y ?? -.infinity)
        var boundsMaximum = SIMD2<Float>(input.bounds?.maximum.x ?? .infinity, input.bounds?.maximum.y ?? .infinity)
        for _ in 0..<configuration.solverIterations {
            guard let contacts = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            contacts.setComputePipelineState(adjacencyContactPipeline); contacts.setBuffer(buffers.particle, offset: 0, index: 0); contacts.setBuffer(buffers.ranges, offset: 0, index: 1)
            contacts.setBuffer(buffers.neighborOffsets, offset: 0, index: 2); contacts.setBuffer(buffers.neighbors, offset: 0, index: 3); contacts.setBuffer(buffers.deltas, offset: 0, index: 4)
            contacts.setBytes(&particleCount, length: 4, index: 5); dispatch(contacts, pipeline: adjacencyContactPipeline, count: particleCountValue); contacts.endEncoding()
            guard let apply = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            apply.setComputePipelineState(applyCorrectionPipeline); apply.setBuffer(buffers.particle, offset: 0, index: 0); apply.setBuffer(buffers.deltas, offset: 0, index: 1)
            apply.setBytes(&particleCount, length: 4, index: 2); dispatch(apply, pipeline: applyCorrectionPipeline, count: particleCountValue); apply.endEncoding()
            guard let shape = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            shape.setComputePipelineState(shapePipeline); shape.setBuffer(buffers.particle, offset: 0, index: 0); shape.setBuffer(buffers.ranges, offset: 0, index: 1)
            shape.setBuffer(buffers.distance, offset: 0, index: 2); shape.setBuffer(buffers.area, offset: 0, index: 3); shape.setBytes(&bubbleCount, length: 4, index: 4); shape.setBytes(&timeStep, length: 4, index: 5)
            dispatch(shape, pipeline: shapePipeline, count: bubbleCountValue); shape.endEncoding()
            if input.bounds != nil {
                guard let bounds = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
                bounds.setComputePipelineState(boundsPipeline); bounds.setBuffer(buffers.particle, offset: 0, index: 0); bounds.setBytes(&particleCount, length: 4, index: 1)
                bounds.setBytes(&boundsMinimum, length: MemoryLayout<SIMD2<Float>>.stride, index: 2); bounds.setBytes(&boundsMaximum, length: MemoryLayout<SIMD2<Float>>.stride, index: 3)
                dispatch(bounds, pipeline: boundsPipeline, count: particleCountValue); bounds.endEncoding()
            }
        }
    }

    private func makeContactPreparation(pairs: [MetalBubblePair], ranges: [MetalBubbleRange]) -> ContactPreparation {
        let rangeByID = Dictionary(uniqueKeysWithValues: ranges.enumerated().map { ($0.element.id, UInt32($0.offset)) })
        let pairIndices = pairs.compactMap { pair -> SIMD2<UInt32>? in
            guard let first = rangeByID[pair.firstID], let second = rangeByID[pair.secondID] else { return nil }
            return SIMD2(first, second)
        }
        var correctionStart = 0
        let pairWork = pairIndices.map { pair -> MetalContactPairWork in
            defer { correctionStart += Int(ranges[Int(pair.x)].boundaryCount + ranges[Int(pair.y)].boundaryCount + 2) }
            return MetalContactPairWork(first: pair.x, second: pair.y, correctionStart: UInt32(correctionStart))
        }
        var correctionTemplates: [MetalCorrection] = []
        correctionTemplates.reserveCapacity(correctionStart)
        for work in pairWork {
            let first = ranges[Int(work.first)]
            let second = ranges[Int(work.second)]
            let start = Int(work.correctionStart)
            correctionTemplates.append(MetalCorrection(particleIndex: first.centerIndex, sourceIndex: UInt32(start), delta: .zero))
            correctionTemplates.append(MetalCorrection(particleIndex: second.centerIndex, sourceIndex: UInt32(start + 1), delta: .zero))
            for offset in 0..<Int(first.boundaryCount) {
                correctionTemplates.append(MetalCorrection(particleIndex: first.boundaryStart + UInt32(offset), sourceIndex: UInt32(start + 2 + offset), delta: .zero))
            }
            for offset in 0..<Int(second.boundaryCount) {
                correctionTemplates.append(MetalCorrection(particleIndex: second.boundaryStart + UInt32(offset), sourceIndex: UInt32(start + 2 + Int(first.boundaryCount) + offset), delta: .zero))
            }
        }
        let gatherOrder = correctionTemplates.sorted {
            $0.particleIndex == $1.particleIndex ? $0.sourceIndex < $1.sourceIndex : $0.particleIndex < $1.particleIndex
        }.map(\.sourceIndex)
        var particleGatherRanges = Array(repeating: SIMD2<UInt32>.zero, count: ranges.reduce(0) { partial, range in
            max(partial, Int(range.boundaryStart + range.boundaryCount))
        })
        var cursor = 0
        while cursor < gatherOrder.count {
            let particleIndex = correctionTemplates[Int(gatherOrder[cursor])].particleIndex
            let start = cursor
            while cursor < gatherOrder.count,
                  correctionTemplates[Int(gatherOrder[cursor])].particleIndex == particleIndex {
                cursor += 1
            }
            particleGatherRanges[Int(particleIndex)] = SIMD2(UInt32(start), UInt32(cursor - start))
        }
        return ContactPreparation(
            pairs: pairs,
            ranges: ranges,
            pairIndices: pairIndices,
            pairWork: pairWork,
            correctionTemplates: correctionTemplates,
            gatherOrder: gatherOrder,
            particleGatherRanges: particleGatherRanges
        )
    }

    private func contactResult(
        particles: [MetalParticle],
        ranges: [MetalBubbleRange],
        candidatePairCount: Int,
        commandPassCount: Int,
        broadPhaseMilliseconds: Double,
        preparationMilliseconds: Double,
        solveMilliseconds: Double
    ) -> MetalContactStepResult {
        let centers = ranges.map { particles[Int($0.centerIndex)].position }
        let separation = centers.count >= 2 ? centers[1] - centers[0] : .zero
        let distance = sqrt(separation.x * separation.x + separation.y * separation.y)
        let areas = ranges.map { range -> Float in
            guard range.boundaryCount >= 3 else { return 0 }
            var doubleArea: Float = 0
            for offset in 0..<Int(range.boundaryCount) {
                let current = particles[Int(range.boundaryStart) + offset].position
                let next = particles[Int(range.boundaryStart) + (offset + 1) % Int(range.boundaryCount)].position
                doubleArea += current.x * next.y - current.y * next.x
            }
            return abs(doubleArea) * 0.5
        }
        return MetalContactStepResult(
            particles: particles,
            centerDistance: distance,
            areas: areas,
            candidatePairCount: candidatePairCount,
            commandPassCount: commandPassCount,
            broadPhaseMilliseconds: broadPhaseMilliseconds,
            preparationMilliseconds: preparationMilliseconds,
            solveMilliseconds: solveMilliseconds
        )
    }

    public func solveInteractions(snapshot: MetalWorldSnapshot, configuration: WorldConfiguration) async throws -> MetalInteractionStepResult {
        var vertices: [SIMD2<Float>] = []
        var polygons: [MetalInteractionPolygon] = []
        for polygon in snapshot.polygons {
            let start = vertices.count
            vertices.append(contentsOf: polygon.worldVertices.map { SIMD2($0.x, $0.y) })
            polygons.append(MetalInteractionPolygon(vertexStart: UInt32(start), vertexCount: UInt32(polygon.worldVertices.count), position: SIMD2(polygon.position.x, polygon.position.y), linearVelocity: SIMD2(polygon.linearVelocity.x, polygon.linearVelocity.y), angularVelocity: polygon.angularVelocity))
        }
        let rangeByID = Dictionary(uniqueKeysWithValues: snapshot.bubbleRanges.map { ($0.id, $0) })
        let grabs = snapshot.grabs.compactMap { grab -> MetalGrab? in
            guard let range = rangeByID[UInt32(grab.bubbleID.rawValue)] else { return nil }
            return MetalGrab(particleIndex: range.centerIndex, target: SIMD2(grab.target.x, grab.target.y), maximumCorrection: 1.5)
        }
        guard let particleBuffer = makeBuffer(snapshot.particles), let vertexBuffer = makeBuffer(vertices, minimumCount: 1), let polygonBuffer = makeBuffer(polygons, minimumCount: 1), let grabBuffer = makeBuffer(grabs, minimumCount: 1), let commandBuffer = commandQueue.makeCommandBuffer() else { throw MetalSolverError.bufferAllocationFailed }
        var particleCount = UInt32(snapshot.particles.count); var polygonCount = UInt32(polygons.count); var grabCount = UInt32(grabs.count); var timeStep = configuration.fixedTimeStep
        if !polygons.isEmpty {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            encoder.setComputePipelineState(polygonPipeline); encoder.setBuffer(particleBuffer, offset: 0, index: 0); encoder.setBuffer(vertexBuffer, offset: 0, index: 1); encoder.setBuffer(polygonBuffer, offset: 0, index: 2); encoder.setBytes(&particleCount, length: 4, index: 3); encoder.setBytes(&polygonCount, length: 4, index: 4); encoder.setBytes(&timeStep, length: 4, index: 5); dispatch(encoder, pipeline: polygonPipeline, count: snapshot.particles.count); encoder.endEncoding()
        }
        if !grabs.isEmpty {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            encoder.setComputePipelineState(grabPipeline); encoder.setBuffer(particleBuffer, offset: 0, index: 0); encoder.setBuffer(grabBuffer, offset: 0, index: 1); encoder.setBytes(&grabCount, length: 4, index: 2); dispatch(encoder, pipeline: grabPipeline, count: grabs.count); encoder.endEncoding()
        }
        commandBuffer.commit(); await commandBuffer.completed()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        let pointer = particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: snapshot.particles.count)
        return MetalInteractionStepResult(particles: Array(UnsafeBufferPointer(start: pointer, count: snapshot.particles.count)))
    }

    public func applyTopologyCommands(_ commands: [MetalTopologyCommand], to snapshot: MetalWorldSnapshot) throws -> MetalWorldSnapshot {
        var bubbles = snapshot.bubbleRanges.map { range in
            TopologyBubble(id: BubbleID(rawValue: Int(range.id)), center: snapshot.particles[Int(range.centerIndex)].position, restArea: range.restArea)
        }
        var nextID = (bubbles.map { $0.id.rawValue }.max() ?? 0) + 1
        for command in commands {
            switch command {
            case let .resize(id, restArea):
                guard let index = bubbles.firstIndex(where: { $0.id == id }), restArea > 0 else { throw MetalSolverError.invalidTopologyCommand }
                bubbles[index].restArea = restArea
            case let .merge(first, second):
                guard let a = bubbles.first(where: { $0.id == first }), let b = bubbles.first(where: { $0.id == second }), first != second else { throw MetalSolverError.invalidTopologyCommand }
                let area = a.restArea + b.restArea
                let center = (a.center * a.restArea + b.center * b.restArea) / area
                bubbles.removeAll { $0.id == first || $0.id == second }
                bubbles.append(TopologyBubble(id: BubbleID(rawValue: nextID), center: center, restArea: area)); nextID += 1
            case let .split(id):
                guard let bubble = bubbles.first(where: { $0.id == id }) else { throw MetalSolverError.invalidTopologyCommand }
                bubbles.removeAll { $0.id == id }
                let area = bubble.restArea * 0.5; let offset = sqrt(area / .pi) * 0.5
                bubbles.append(TopologyBubble(id: BubbleID(rawValue: nextID), center: bubble.center + SIMD2(-offset, 0), restArea: area)); nextID += 1
                bubbles.append(TopologyBubble(id: BubbleID(rawValue: nextID), center: bubble.center + SIMD2(offset, 0), restArea: area)); nextID += 1
            }
        }
        return rebuildTopology(bubbles, preserving: snapshot)
    }

    private func rebuildTopology(_ bubbles: [TopologyBubble], preserving snapshot: MetalWorldSnapshot) -> MetalWorldSnapshot {
        var particles: [MetalParticle] = []; var ranges: [MetalBubbleRange] = []; var distances: [MetalDistanceConstraint] = []; var areas: [MetalAreaConstraint] = []
        for (bubbleIndex, bubble) in bubbles.sorted(by: { $0.id < $1.id }).enumerated() {
            let topology = BubbleTopology.regular(id: bubble.id, center: Vector2(x: bubble.center.x, y: bubble.center.y), restArea: bubble.restArea, maxBoundarySegmentLength: snapshot.configuration.maxBoundarySegmentLength)
            let centerIndex = particles.count
            particles.append(MetalParticle(position: bubble.center, previousPosition: bubble.center, inverseMass: 1, bubbleIndex: UInt32(bubbleIndex)))
            let boundaryStart = particles.count
            particles.append(contentsOf: topology.boundaryPoints.map { point in MetalParticle(position: SIMD2(point.x, point.y), previousPosition: SIMD2(point.x, point.y), inverseMass: 1, bubbleIndex: UInt32(bubbleIndex)) })
            let constraintStart = distances.count
            for offset in topology.boundaryPoints.indices {
                let current = boundaryStart + offset, next = boundaryStart + (offset + 1) % topology.boundaryPoints.count, diagonal = boundaryStart + (offset + 2) % topology.boundaryPoints.count
                distances.append(MetalDistanceConstraint(firstIndex: UInt32(centerIndex), secondIndex: UInt32(current), restLength: vectorDistance(particles[centerIndex].position, particles[current].position), compliance: 0))
                distances.append(MetalDistanceConstraint(firstIndex: UInt32(current), secondIndex: UInt32(next), restLength: vectorDistance(particles[current].position, particles[next].position), compliance: 0))
                distances.append(MetalDistanceConstraint(firstIndex: UInt32(current), secondIndex: UInt32(diagonal), restLength: vectorDistance(particles[current].position, particles[diagonal].position), compliance: 0))
            }
            ranges.append(MetalBubbleRange(id: UInt32(bubble.id.rawValue), centerIndex: UInt32(centerIndex), boundaryStart: UInt32(boundaryStart), boundaryCount: UInt32(topology.boundaryPoints.count), restArea: bubble.restArea, distanceConstraintStart: UInt32(constraintStart), distanceConstraintCount: UInt32(distances.count - constraintStart)))
            areas.append(MetalAreaConstraint(boundaryStart: UInt32(boundaryStart), boundaryCount: UInt32(topology.boundaryPoints.count), restArea: bubble.restArea, compliance: 0))
        }
        return MetalWorldSnapshot(particles: particles, bubbleRanges: ranges, distanceConstraints: distances, areaConstraints: areas, polygons: snapshot.polygons, grabs: snapshot.grabs, configuration: snapshot.configuration)
    }

    private func vectorDistance(_ first: SIMD2<Float>, _ second: SIMD2<Float>) -> Float {
        let delta = second - first; return sqrt(delta.x * delta.x + delta.y * delta.y)
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

public struct MetalContactStepResult: Equatable, Sendable {
    public let particles: [MetalParticle]
    public let centerDistance: Float
    public let areas: [Float]
    public let candidatePairCount: Int
    public let commandPassCount: Int
    public let broadPhaseMilliseconds: Double
    public let preparationMilliseconds: Double
    public let solveMilliseconds: Double
}

public struct MetalInteractionStepResult: Equatable, Sendable { public let particles: [MetalParticle] }

public enum MetalTopologyCommand: Equatable, Sendable {
    case resize(BubbleID, restArea: Float)
    case merge(BubbleID, BubbleID)
    case split(BubbleID)
}

private struct TopologyBubble {
    let id: BubbleID
    var center: SIMD2<Float>
    var restArea: Float
}

private struct MetalContactPairWork {
    let first: UInt32
    let second: UInt32
    let correctionStart: UInt32
    let padding: UInt32 = 0
}

private struct ContactPreparation {
    let pairs: [MetalBubblePair]
    let ranges: [MetalBubbleRange]
    let pairIndices: [SIMD2<UInt32>]
    let pairWork: [MetalContactPairWork]
    let correctionTemplates: [MetalCorrection]
    let gatherOrder: [UInt32]
    let particleGatherRanges: [SIMD2<UInt32>]
}

public enum MetalSolverError: Error {
    case bufferAllocationFailed
    case commandEncodingFailed
    case commandExecutionFailed
    case candidatePairOverflow
    case invalidTopologyCommand
    case metalUnavailable
}
