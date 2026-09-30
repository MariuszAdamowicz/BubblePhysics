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
    private let reductionPipeline: MTLComputePipelineState
    private let contactPipeline: MTLComputePipelineState
    private let applyCorrectionPipeline: MTLComputePipelineState
    private let correctionSortPipeline: MTLComputePipelineState
    private let polygonPipeline: MTLComputePipelineState
    private let grabPipeline: MTLComputePipelineState

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
              let contactURL = Bundle.module.url(forResource: "ContactKernels", withExtension: "metal"),
              let contactSource = try? String(contentsOf: contactURL),
              let contactLibrary = try? device.makeLibrary(source: contactSource, options: nil),
              let reductionFunction = contactLibrary.makeFunction(name: "reduceCorrections"),
              let contactFunction = contactLibrary.makeFunction(name: "generateBubbleContacts"),
              let applyCorrectionFunction = contactLibrary.makeFunction(name: "applyCorrections"),
              let correctionSortFunction = contactLibrary.makeFunction(name: "sortCorrectionsByParticle"),
              let polygonURL = Bundle.module.url(forResource: "PolygonKernels", withExtension: "metal"),
              let polygonSource = try? String(contentsOf: polygonURL),
              let polygonLibrary = try? device.makeLibrary(source: polygonSource, options: nil),
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
              , let buildPipeline = try? device.makeComputePipelineState(function: buildFunction),
              let reductionPipeline = try? device.makeComputePipelineState(function: reductionFunction),
              let contactPipeline = try? device.makeComputePipelineState(function: contactFunction),
              let applyCorrectionPipeline = try? device.makeComputePipelineState(function: applyCorrectionFunction)
              , let correctionSortPipeline = try? device.makeComputePipelineState(function: correctionSortFunction)
              , let polygonPipeline = try? device.makeComputePipelineState(function: polygonFunction),
              let grabPipeline = try? device.makeComputePipelineState(function: grabFunction)
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
        self.reductionPipeline = reductionPipeline
        self.contactPipeline = contactPipeline
        self.applyCorrectionPipeline = applyCorrectionPipeline
        self.correctionSortPipeline = correctionSortPipeline
        self.polygonPipeline = polygonPipeline
        self.grabPipeline = grabPipeline
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

    public func reduceCorrectionsForTesting(_ corrections: [MetalCorrection]) async throws -> [Int: SIMD2<Float>] {
        let particleCount = Int((corrections.map(\.particleIndex).max() ?? 0) + 1)
        guard particleCount > 0, let correctionBuffer = makeBuffer(corrections), let resultBuffer = device.makeBuffer(length: particleCount * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared), let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else { return [:] }
        var count = UInt32(corrections.count); var particles = UInt32(particleCount)
        encoder.setComputePipelineState(reductionPipeline); encoder.setBuffer(correctionBuffer, offset: 0, index: 0); encoder.setBuffer(resultBuffer, offset: 0, index: 1); encoder.setBytes(&count, length: 4, index: 2); encoder.setBytes(&particles, length: 4, index: 3); dispatch(encoder, pipeline: reductionPipeline, count: particleCount); encoder.endEncoding(); commandBuffer.commit(); await commandBuffer.completed()
        let values = resultBuffer.contents().bindMemory(to: SIMD2<Float>.self, capacity: particleCount)
        return Dictionary(uniqueKeysWithValues: (0..<particleCount).map { ($0, values[$0]) })
    }

    public func solveContacts(snapshot: MetalWorldSnapshot, configuration: WorldConfiguration) async throws -> MetalContactStepResult {
        let pairs = try await candidatePairs(snapshot: snapshot)
        guard !pairs.isEmpty else { return contactResult(particles: snapshot.particles, ranges: snapshot.bubbleRanges) }
        let rangeByID = Dictionary(uniqueKeysWithValues: snapshot.bubbleRanges.enumerated().map { ($0.element.id, UInt32($0.offset)) })
        let pairIndices = pairs.compactMap { pair -> SIMD2<UInt32>? in
            guard let first = rangeByID[pair.firstID], let second = rangeByID[pair.secondID] else { return nil }
            return SIMD2(first, second)
        }
        let correctionCapacity = pairIndices.reduce(0) { partial, pair in
            partial + Int(snapshot.bubbleRanges[Int(pair.x)].boundaryCount + snapshot.bubbleRanges[Int(pair.y)].boundaryCount + 2)
        }
        var correctionStart = 0
        let pairWork = pairIndices.map { pair -> MetalContactPairWork in
            defer { correctionStart += Int(snapshot.bubbleRanges[Int(pair.x)].boundaryCount + snapshot.bubbleRanges[Int(pair.y)].boundaryCount + 2) }
            return MetalContactPairWork(first: pair.x, second: pair.y, correctionStart: UInt32(correctionStart))
        }
        let sortedCorrectionCount = nextPowerOfTwo(max(1, correctionCapacity))
        let emptyCorrections = (0..<sortedCorrectionCount).map { MetalCorrection(particleIndex: .max, sourceIndex: UInt32($0), delta: .zero) }
        _ = capacityManager.ensureCapacity(for: MetalBufferRequirements(pairs: pairs.count, contacts: pairs.count, corrections: correctionCapacity))
        guard let particleBuffer = makeBuffer(snapshot.particles), let rangeBuffer = makeBuffer(snapshot.bubbleRanges), let pairBuffer = makeBuffer(pairWork), let distanceBuffer = makeBuffer(snapshot.distanceConstraints, minimumCount: 1), let areaBuffer = makeBuffer(snapshot.areaConstraints, minimumCount: 1), let correctionBuffer = makeBuffer(emptyCorrections), let reducedBuffer = device.makeBuffer(length: snapshot.particles.count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared), let commandBuffer = commandQueue.makeCommandBuffer() else { throw MetalSolverError.bufferAllocationFailed }
        var pairCount = UInt32(pairIndices.count); var encodedCorrectionCount = UInt32(sortedCorrectionCount); var particleCount = UInt32(snapshot.particles.count)
        var bubbleCount = UInt32(snapshot.bubbleRanges.count)
        var timeStep = configuration.fixedTimeStep
        for _ in 0..<configuration.solverIterations {
            guard let clearEncoder = commandBuffer.makeBlitCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            clearEncoder.fill(buffer: reducedBuffer, range: 0..<reducedBuffer.length, value: 0)
            clearEncoder.endEncoding()
            guard let contactEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            contactEncoder.setComputePipelineState(contactPipeline); contactEncoder.setBuffer(particleBuffer, offset: 0, index: 0); contactEncoder.setBuffer(rangeBuffer, offset: 0, index: 1); contactEncoder.setBuffer(pairBuffer, offset: 0, index: 2); contactEncoder.setBuffer(correctionBuffer, offset: 0, index: 3); contactEncoder.setBytes(&pairCount, length: 4, index: 4); dispatch(contactEncoder, pipeline: contactPipeline, count: pairIndices.count); contactEncoder.endEncoding()
            var stage = 2
            while stage <= sortedCorrectionCount {
                var strideValue = stage / 2
                while strideValue > 0 {
                    var encodedStage = UInt32(stage); var encodedStride = UInt32(strideValue)
                    guard let sortEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
                    sortEncoder.setComputePipelineState(correctionSortPipeline); sortEncoder.setBuffer(correctionBuffer, offset: 0, index: 0); sortEncoder.setBytes(&encodedCorrectionCount, length: 4, index: 1); sortEncoder.setBytes(&encodedStage, length: 4, index: 2); sortEncoder.setBytes(&encodedStride, length: 4, index: 3); dispatch(sortEncoder, pipeline: correctionSortPipeline, count: sortedCorrectionCount); sortEncoder.endEncoding()
                    strideValue /= 2
                }
                stage *= 2
            }
            guard let reduceEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            reduceEncoder.setComputePipelineState(reductionPipeline); reduceEncoder.setBuffer(correctionBuffer, offset: 0, index: 0); reduceEncoder.setBuffer(reducedBuffer, offset: 0, index: 1); reduceEncoder.setBytes(&encodedCorrectionCount, length: 4, index: 2); dispatch(reduceEncoder, pipeline: reductionPipeline, count: sortedCorrectionCount); reduceEncoder.endEncoding()
            guard let applyEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            applyEncoder.setComputePipelineState(applyCorrectionPipeline); applyEncoder.setBuffer(particleBuffer, offset: 0, index: 0); applyEncoder.setBuffer(reducedBuffer, offset: 0, index: 1); applyEncoder.setBytes(&particleCount, length: 4, index: 2); dispatch(applyEncoder, pipeline: applyCorrectionPipeline, count: snapshot.particles.count); applyEncoder.endEncoding()
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
        }
        commandBuffer.commit(); await commandBuffer.completed()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        let pointer = particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: snapshot.particles.count)
        return contactResult(particles: Array(UnsafeBufferPointer(start: pointer, count: snapshot.particles.count)), ranges: snapshot.bubbleRanges)
    }

    private func contactResult(particles: [MetalParticle], ranges: [MetalBubbleRange]) -> MetalContactStepResult {
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
        return MetalContactStepResult(particles: particles, centerDistance: distance, areas: areas)
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

public enum MetalSolverError: Error {
    case bufferAllocationFailed
    case commandEncodingFailed
    case commandExecutionFailed
    case candidatePairOverflow
    case invalidTopologyCommand
}
