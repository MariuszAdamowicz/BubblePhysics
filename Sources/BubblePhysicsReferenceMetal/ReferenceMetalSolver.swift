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

struct ReferenceMetalPreparedComponent {
    let bubbleIDs: [ReferenceBubbleID]
    let contactIDs: [ReferenceContactID]
}

struct ReferenceMetalPreparedFrame {
    let predictedCenters: [ReferenceVector2]
    let centers: [ReferenceVector2]
    let contacts: [ReferenceContact]
    let candidatePairs: [ReferencePair]
    let eventGroups: [ReferenceContactEventGroup]
    let allEvents: [ReferenceContactEvent]
    let impactContacts: [ReferenceContact]
    let didReachEventGroupLimit: Bool
    let ccdBudgetExhaustionCount: Int
    let sideCorrectionCount: Int
    let componentLabels: [Int?]
    let components: [ReferenceMetalPreparedComponent]
    let didOverflow: Bool
    let attemptCount: Int
}

struct ReferenceMetalGeometryParameters {
    var counts: SIMD4<UInt32>
    var capacities: SIMD4<UInt32>
    var physics: SIMD4<Float>
    var events: SIMD4<Float>
    var limits: SIMD4<UInt32>
}

struct ReferenceMetalGeometryControl {
    var counts: SIMD4<UInt32>
    var required: SIMD4<UInt32>
    var flags: SIMD4<UInt32>
    var grouping: SIMD4<UInt32>
}

struct ReferenceMetalGeometryEvent {
    var contact: ReferenceMetalContact
    var timing: SIMD4<Float>
    var grouping: SIMD4<UInt32>
}

enum ReferenceMetalGeometryError: Error { case nonFiniteState, invalidOverflowReport }

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
    private let geometryPipelines: [String: MTLComputePipelineState]
    private let worldPipelines: [String: MTLComputePipelineState]
    private let commandQueue: MTLCommandQueue
    private var operatorBuffers: [String: MTLBuffer] = [:]
    private var evaluationInFlight = false
    let capacityManager: ReferenceMetalCapacityManager

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        let options = MTLCompileOptions()
        options.fastMathEnabled = false
        options.languageVersion = .version2_4 // iOS 16 baseline, including copied runtime resources.
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
              let commandQueue = device.makeCommandQueue(),
              let geometryURL = Bundle.module.url(forResource: "ReferenceGeometryKernels", withExtension: "metal"),
              let geometrySource = try? String(contentsOf: geometryURL, encoding: .utf8),
              let geometryLibrary = try? device.makeLibrary(source: geometrySource, options: options)
        else { return nil }

        var geometryPipelines: [String: MTLComputePipelineState] = [:]
        for name in ["referencePredict", "referenceEmitCandidatePairs", "referenceRefreshContacts", "referenceFindTOI", "referenceLabelComponents"] {
            guard let function = geometryLibrary.makeFunction(name: name),
                  let state = try? device.makeComputePipelineState(function: function) else { return nil }
            geometryPipelines[name] = state
        }

        guard let postURL = Bundle.module.url(forResource: "ReferencePostSolveKernels", withExtension: "metal"),
              let postSource = try? String(contentsOf: postURL, encoding: .utf8),
              let worldLibrary = try? device.makeLibrary(source: "#define REFERENCE_WORLD_RUNTIME 1\n" + source + "\n" + geometrySource + "\n" + postSource, options: options)
        else { return nil }
        var worldPipelines: [String: MTLComputePipelineState] = [:]
        for name in ["referenceAdvanceWorld", "referenceApplyCenterGuards", "referenceGenerateContours", "referencePrepareRenderData"] {
            guard let function = worldLibrary.makeFunction(name: name),
                  let state = try? device.makeComputePipelineState(function: function) else { return nil }
            worldPipelines[name] = state
        }

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
        self.geometryPipelines = geometryPipelines
        self.worldPipelines = worldPipelines
        loadedFunctionNames = Set([function.name, jacobian.name, diagonal.name, dot.name,
                              pcgInitialize.name, pcgAdvance.name, pcgDirection.name, pcgFinalize.name]).union(geometryPipelines.keys).union(worldPipelines.keys)
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

    /// Preparation only: ballistic prediction, CPU-equilibrium contact refresh,
    /// independent CCD/event scan and contact partition. No solve or finalization.
    /// `centers` is a guarded trial, while refresh/CCD use `predictedCenters`.
    func prepareFrameForTesting(snapshot: ReferenceMetalSnapshot, step: Int) async throws -> ReferenceMetalPreparedFrame {
        guard !evaluationInFlight else { throw ReferenceMetalOperatorError.evaluationInFlight }
        let n = snapshot.bubbles.count, segmentCount = snapshot.segments.count
        let (square, squareOverflow) = n.multipliedReportingOverflow(by: max(0, n - 1))
        let (segmentPairs, segmentOverflow) = n.multipliedReportingOverflow(by: segmentCount)
        let (pairUpper, pairOverflow) = (square / 2).addingReportingOverflow(segmentPairs)
        let (contactUpper, contactOverflow) = pairUpper.addingReportingOverflow(snapshot.contacts.count)
        guard !squareOverflow, !segmentOverflow, !pairOverflow, !contactOverflow,
              snapshot.centers.count == n, snapshot.velocities.count == n,
              let bubbles = UInt32(exactly: n), let segments = UInt32(exactly: segmentCount),
              let previous = UInt32(exactly: snapshot.contacts.count),
              let upper = UInt32(exactly: contactUpper), let step = UInt32(exactly: step),
              let budget = UInt32(exactly: snapshot.configuration.toiIterationBudget),
              let groupLimit = UInt32(exactly: snapshot.configuration.maximumEventGroups),
              snapshot.configuration.timeStep.isFinite, snapshot.configuration.timeStep > 0
        else { throw ReferenceMetalOperatorError.invalidInput }
        evaluationInFlight = true
        defer { evaluationInFlight = false }
        var pairCapacity = max(1, (operatorBuffers["geometryPairs"]?.length ?? 0) / MemoryLayout<SIMD4<UInt32>>.stride)
        var contactCapacity = max(1, snapshot.contacts.count,
            (operatorBuffers["geometryContacts"]?.length ?? 0) / MemoryLayout<ReferenceMetalContact>.stride)
        var componentCapacity = max(1, (operatorBuffers["geometryComponents"]?.length ?? 0) / MemoryLayout<SIMD4<UInt32>>.stride)
        var attempts = 0, didOverflow = false
        while true {
            try Task.checkCancellation()
            attempts += 1
            let inputs = try [upload(snapshot.bubbles, name: "geometryBubbles"),
                upload(snapshot.centers, name: "geometryStart"), upload(snapshot.velocities, name: "geometryVelocity"),
                upload(snapshot.segments, name: "geometrySegments"), upload(snapshot.contacts, name: "geometryPrevious")]
            let vectorStride = MemoryLayout<SIMD2<Float>>.stride
            let predicted = try buffer(name: "geometryPredicted", count: n, stride: vectorStride)
            let guarded = try buffer(name: "geometryGuarded", count: n, stride: vectorStride)
            let pairs = try buffer(name: "geometryPairs", count: pairCapacity, stride: MemoryLayout<SIMD4<UInt32>>.stride)
            let contacts = try buffer(name: "geometryContacts", count: contactCapacity, stride: MemoryLayout<ReferenceMetalContact>.stride)
            let events = try buffer(name: "geometryEvents", count: pairCapacity, stride: MemoryLayout<ReferenceMetalGeometryEvent>.stride)
            let labels = try buffer(name: "geometryLabels", count: n, stride: MemoryLayout<UInt32>.stride)
            let touched = try buffer(name: "geometryTouched", count: n, stride: MemoryLayout<UInt32>.stride)
            let components = try buffer(name: "geometryComponents", count: componentCapacity, stride: MemoryLayout<SIMD4<UInt32>>.stride)
            let control = try buffer(name: "geometryControl", count: 1, stride: MemoryLayout<ReferenceMetalGeometryControl>.stride)
            memset(control.contents(), 0, control.length)
            let buffers = inputs + [predicted, guarded, pairs, contacts, events, labels, touched, components, control]
            guard let command = commandQueue.makeCommandBuffer() else { throw ReferenceMetalOperatorError.commandSetupFailed }
            let config = snapshot.configuration
            var parameters = ReferenceMetalGeometryParameters(counts: SIMD4(bubbles, segments, previous, UInt32(pairCapacity)),
                capacities: SIMD4(UInt32(contactCapacity), UInt32(componentCapacity), 0, 0),
                physics: SIMD4(config.timeStep, config.contactTolerance, config.separationTolerance, config.positionTolerance),
                events: SIMD4(config.simultaneousEventTolerance, 0, 0, 0), limits: SIMD4(budget, groupLimit, upper, step))
            func encode(_ name: String, parallel: Bool = false) throws {
                guard !parallel || n > 0 else { return }
                guard let pipeline = geometryPipelines[name], let encoder = command.makeComputeCommandEncoder()
                else { throw ReferenceMetalOperatorError.commandSetupFailed }
                encoder.setComputePipelineState(pipeline)
                for (i, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: i) }
                encoder.setBytes(&parameters, length: MemoryLayout<ReferenceMetalGeometryParameters>.stride, index: 14)
                encoder.dispatchThreads(MTLSize(width: parallel ? n : 1, height: 1, depth: 1),
                    threadsPerThreadgroup: MTLSize(width: parallel ? min(256, pipeline.maxTotalThreadsPerThreadgroup) : 1, height: 1, depth: 1))
                encoder.endEncoding()
            }
            try encode("referencePredict", parallel: true)
            try encode("referenceEmitCandidatePairs")
            try encode("referenceRefreshContacts")
            try encode("referenceFindTOI")
            parameters.capacities.z = 1
            try encode("referencePredict", parallel: true)
            try encode("referenceLabelComponents")
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                command.addCompletedHandler { completed in
                    if completed.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: ReferenceMetalOperatorError.executionFailed(completed.error?.localizedDescription ?? "Metal command failed")) }
                }
                command.commit()
            }
            try Task.checkCancellation()
            let state = control.contents().load(as: ReferenceMetalGeometryControl.self)
            if state.flags.x != 0 {
                let required = [Int(state.required.x), Int(state.required.y), Int(state.required.z)]
                guard required[0] > pairCapacity || required[1] > contactCapacity || required[2] > componentCapacity
                else { throw ReferenceMetalGeometryError.invalidOverflowReport }
                pairCapacity = max(pairCapacity, required[0])
                contactCapacity = max(contactCapacity, required[1])
                componentCapacity = max(componentCapacity, required[2])
                didOverflow = true
                continue // Discard all partial results; reupload the immutable snapshot.
            }
            guard state.flags.y == 0 else { throw ReferenceMetalGeometryError.nonFiniteState }
            func values<T>(_ buffer: MTLBuffer, count: Int, type: T.Type) -> [T] {
                Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
            }
            func vectors(_ buffer: MTLBuffer) -> [ReferenceVector2] {
                values(buffer, count: n, type: SIMD2<Float>.self).map { .init(x: $0.x, y: $0.y) }
            }
            let packedContacts = values(contacts, count: Int(state.counts.y), type: ReferenceMetalContact.self)
            let resultContacts = packedContacts.map(Self.unpackContact)
            let resultEvents = values(events, count: Int(state.counts.z), type: ReferenceMetalGeometryEvent.self)
            let allEvents = resultEvents.map { ReferenceContactEvent(time: $0.timing.x, contactID: .init(rawValue: $0.contact.identity.x)) }
            let groups = (0..<min(Int(state.grouping.x), Int(groupLimit))).map { group in
                let members = resultEvents.filter { Int($0.grouping.x) == group }
                return ReferenceContactEventGroup(time: members[0].timing.z, events: members.map {
                    .init(time: $0.timing.x, contactID: .init(rawValue: $0.contact.identity.x))
                })
            }
            let roots = values(labels, count: n, type: UInt32.self)
            let membership = values(touched, count: n, type: UInt32.self)
            let records = values(components, count: Int(state.counts.w), type: SIMD4<UInt32>.self)
            let resultComponents = records.map { record in
                let ids = (0..<n).filter { membership[$0] != 0 && roots[$0] == record.x }.map {
                    ReferenceBubbleID(rawValue: Int(snapshot.bubbles[$0].identity.x))
                }
                let idSet = Set(ids)
                return ReferenceMetalPreparedComponent(bubbleIDs: ids, contactIDs: resultContacts.filter {
                    idSet.contains($0.bubbleA) || $0.bubbleB.map(idSet.contains) == true
                }.map(\.id))
            }
            let rootToLabel = Dictionary(uniqueKeysWithValues: records.enumerated().map { ($0.element.x, $0.offset) })
            let resultPairs = values(pairs, count: Int(state.counts.x), type: SIMD4<UInt32>.self).filter { $0.x == 0 }.map {
                ReferencePair(.init(rawValue: Int(snapshot.bubbles[Int($0.y)].identity.x)),
                              .init(rawValue: Int(snapshot.bubbles[Int($0.z)].identity.x)))
            }
            return .init(predictedCenters: vectors(predicted), centers: vectors(guarded), contacts: resultContacts,
                candidatePairs: resultPairs, eventGroups: groups, allEvents: allEvents,
                impactContacts: resultEvents.map { Self.unpackContact($0.contact) }, didReachEventGroupLimit: state.grouping.y != 0,
                ccdBudgetExhaustionCount: Int(state.flags.z), sideCorrectionCount: Int(state.flags.w),
                componentLabels: (0..<n).map { membership[$0] == 0 ? nil : rootToLabel[roots[$0]] },
                components: resultComponents, didOverflow: didOverflow, attemptCount: attempts)
        }
    }

    private static func unpackContact(_ c: ReferenceMetalContact) -> ReferenceContact {
        let flags = c.identity.y
        return .init(id: .init(rawValue: c.identity.x), kind: flags & 1 != 0 ? .bubbleSegment : .bubbleBubble,
            bubbleA: .init(rawValue: Int(c.bubbles.x)), bubbleB: flags & 2 != 0 ? .init(rawValue: Int(c.bubbles.y)) : nil,
            segment: flags & 4 != 0 ? .init(rawValue: Int(c.segmentAndAge.x)) : nil,
            normal: .init(x: c.geometry.x, y: c.geometry.y), pointQ: .init(x: c.geometry.z, y: c.geometry.w),
            penetration: c.timing.x, timeOfImpact: flags & 8 != 0 ? c.timing.y : nil,
            allowedSide: flags & 16 != 0 ? c.timing.z : nil, accumulatedCompression: c.compression.x,
            compressionA: c.compression.y, compressionB: c.compression.z, pressure: c.compression.w,
            effectiveStiffness: c.response.x, age: Int(c.segmentAndAge.y), contourHalfLength: flags & 32 != 0 ? c.timing.w : nil)
    }

    @MainActor
    func executeFrame(snapshot: ReferenceMetalSnapshot, scenarioStep: Int) async throws -> ReferenceMetalWorldFrame {
        guard !evaluationInFlight else { throw ReferenceMetalOperatorError.evaluationInFlight }
        let startTime = DispatchTime.now().uptimeNanoseconds
        let n = snapshot.bubbles.count, segmentCount = snapshot.segments.count
        let (square, squareOverflow) = n.multipliedReportingOverflow(by: max(0, n - 1))
        let (segmentPairs, segmentOverflow) = n.multipliedReportingOverflow(by: segmentCount)
        let (upper, upperOverflow) = (square / 2).addingReportingOverflow(segmentPairs)
        let (required, requiredOverflow) = upper.addingReportingOverflow(snapshot.contacts.count)
        let config = snapshot.configuration
        guard !squareOverflow, !segmentOverflow, !upperOverflow, !requiredOverflow,
              let bubbleCount = UInt32(exactly: n), let segments = UInt32(exactly: segmentCount),
              let oldCount = UInt32(exactly: snapshot.contacts.count), UInt32(exactly: required) != nil,
              let newtonLimit = UInt32(exactly: config.solverIterations),
              let toiLimit = UInt32(exactly: config.toiIterationBudget),
              let eventLimit = UInt32(exactly: config.maximumEventGroups), scenarioStep >= 0,
              snapshot.centers.count == n, snapshot.velocities.count == n
        else { throw ReferenceMetalOperatorError.invalidInput }
        evaluationInFlight = true
        defer { evaluationInFlight = false }
        var ranges: [SIMD2<UInt32>] = []
        var pointCount = 0
        for bubble in snapshot.bubbles {
            let floatCount = ceilf(2 * Float.pi * bubble.physical.z / config.maxContourSegmentLength)
            guard floatCount.isFinite, floatCount >= 0, floatCount < Float(UInt32.max),
                  let offset = UInt32(exactly: pointCount) else { throw ReferenceMetalOperatorError.invalidInput }
            let count = max(32, Int(floatCount))
            let (next, overflow) = pointCount.addingReportingOverflow(count)
            guard !overflow, let packedCount = UInt32(exactly: count), UInt32(exactly: next) != nil
            else { throw ReferenceMetalOperatorError.invalidInput }
            ranges.append(SIMD2(offset, packedCount))
            pointCount = next
        }
        var contactCapacity = max(1, snapshot.contacts.count,
            (operatorBuffers["worldContacts"]?.length ?? 0) / (5 * MemoryLayout<ReferenceMetalContact>.stride))
        var didOverflow = false
        while true {
            try Task.checkCancellation()
            let inputBuffers = try [upload(snapshot.bubbles, name: "worldBubbles"),
                upload(snapshot.centers, name: "worldInput"), upload(snapshot.velocities, name: "worldInputVelocity"),
                upload(snapshot.segments, name: "worldSegments"), upload(snapshot.contacts, name: "worldPrevious")]
            let vectors = try buffer(name: "worldVectors", count: n, stride: 19 * MemoryLayout<SIMD2<Float>>.stride)
            let contacts = try buffer(name: "worldContacts", count: contactCapacity, stride: 5 * MemoryLayout<ReferenceMetalContact>.stride)
            let intervalSegments = try buffer(name: "worldIntervalSegments", count: segmentCount, stride: MemoryLayout<ReferenceMetalSegment>.stride)
            let events = try buffer(name: "worldEvents", count: contactCapacity, stride: MemoryLayout<ReferenceMetalGeometryEvent>.stride)
            let labels = try buffer(name: "worldLabels", count: n, stride: 2 * MemoryLayout<UInt32>.stride)
            let control = try buffer(name: "worldControl", count: 1, stride: MemoryLayout<ReferenceMetalWorldControl>.stride)
            let rangeBuffer = try upload(ranges, name: "worldContourRanges")
            let points = try buffer(name: "worldContourPoints", count: pointCount, stride: MemoryLayout<SIMD2<Float>>.stride)
            let render = try buffer(name: "worldRender", count: n, stride: MemoryLayout<SIMD4<Float>>.stride)
            let buffers = inputBuffers + [vectors, contacts, intervalSegments, events, labels, control, rangeBuffer, points, render]
            guard let command = commandQueue.makeCommandBuffer(), let capacity = UInt32(exactly: contactCapacity)
            else { throw ReferenceMetalOperatorError.commandSetupFailed }
            var parameters = ReferenceMetalWorldParameters(counts: SIMD4(bubbleCount, segments, oldCount, capacity),
                physics: SIMD4(config.timeStep, config.contactStiffness, config.nonlinearStiffening, config.contactDamping),
                damping: SIMD4(config.linearDamping, config.angularDamping, config.surfaceFriction, config.angularFrictionCoupling),
                tolerances: SIMD4(config.contactTolerance, config.separationTolerance, config.positionTolerance, config.stressTolerance),
                shape: SIMD4(config.maxContourSegmentLength, config.contourSurfaceTension, config.pcgTolerance, config.simultaneousEventTolerance),
                limits: SIMD4(newtonLimit, UInt32(min(16, config.pcgIterationLimit)), toiLimit, eventLimit))
            for name in ["referenceAdvanceWorld", "referenceApplyCenterGuards", "referenceGenerateContours", "referencePrepareRenderData"] {
                let width = name == "referenceGenerateContours" ? n : 1
                if width == 0 { continue }
                guard let pipeline = worldPipelines[name], let encoder = command.makeComputeCommandEncoder()
                else { throw ReferenceMetalOperatorError.commandSetupFailed }
                encoder.setComputePipelineState(pipeline)
                for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
                encoder.setBytes(&parameters, length: MemoryLayout<ReferenceMetalWorldParameters>.stride, index: 14)
                encoder.dispatchThreads(.init(width: width, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: min(width, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
                encoder.endEncoding()
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                command.addCompletedHandler { completed in
                    if completed.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: ReferenceMetalOperatorError.executionFailed(completed.error?.localizedDescription ?? "Metal command failed")) }
                }
                command.commit()
            }
            try Task.checkCancellation()
            let state = control.contents().load(as: ReferenceMetalWorldControl.self)
            if state.failure.y != 0 {
                guard Int(state.failure.z) > contactCapacity else { throw ReferenceMetalGeometryError.invalidOverflowReport }
                contactCapacity = Int(state.failure.z)
                didOverflow = true
                continue // All outputs discarded, same input and controls re-uploaded.
            }
            guard state.failure.x == 0 else { throw ReferenceMetalGeometryError.nonFiniteState }
            guard state.failure.w == 0 else { throw ReferenceMetalWorldError.guardFailed }
            guard Int(state.failure.z) <= contactCapacity else { throw ReferenceMetalGeometryError.invalidOverflowReport }
            func values<T>(_ buffer: MTLBuffer, count: Int, type: T.Type) -> [T] {
                Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: T.self, capacity: count), count: count))
            }
            let vectorValues = values(vectors, count: 2 * n, type: SIMD2<Float>.self)
            let packedBubbles = values(inputBuffers[0], count: n, type: ReferenceMetalBubble.self)
            let resultBubbles = try (0..<n).map { i -> ReferenceBubble in
                let packed = packedBubbles[i]
                var bubble = try ReferenceBubble(id: .init(rawValue: Int(packed.identity.x)),
                    center: .init(x: vectorValues[i].x, y: vectorValues[i].y),
                    velocity: .init(x: vectorValues[n + i].x, y: vectorValues[n + i].y),
                    mass: packed.physical.x, targetRadius: packed.physical.z, stiffness: packed.physical.w,
                    rotation: packed.angular.x, angularVelocity: packed.angular.y)
                bubble.previousCenter = .init(x: snapshot.centers[i].x, y: snapshot.centers[i].y)
                bubble.inverseMass = packed.physical.y
                return bubble
            }
            let resultContacts = values(contacts, count: Int(state.failure.z), type: ReferenceMetalContact.self).map(Self.unpackContact)
            let pointValues = values(points, count: pointCount, type: SIMD2<Float>.self)
            let resultContours = Dictionary(uniqueKeysWithValues: (0..<n).map { i in
                (resultBubbles[i].id, pointValues[Int(ranges[i].x)..<(Int(ranges[i].x) + Int(ranges[i].y))].map { ReferenceVector2(x: $0.x, y: $0.y) })
            })
            let flags = state.solverCounts.w
            let reportSolver = ReferenceSolverReport(iterations: Int(state.solverCounts.x), maximumPenetration: state.solverQuality.z,
                converged: flags & 1 != 0, didReachIterationLimit: flags & 2 != 0, positionCorrectionCount: 0,
                deformationCount: 0, pcgIterationCount: Int(state.solverCounts.y), initialResidualNorm: state.solverQuality.x,
                finalResidualNorm: state.solverQuality.y, maximumRelativeDeformation: state.solverQuality.w,
                lineSearchFailureCount: Int(state.solverCounts.z), hasNonFiniteState: flags & 4 != 0,
                contactComponentCount: Int(state.solverComponents.x), unconvergedContactComponentCount: Int(state.solverComponents.y),
                maximumComponentResidualNorm: state.solverComponents.z)
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - startTime) / 1_000_000
            let gpuTime = max(0, command.gpuEndTime - command.gpuStartTime) * 1_000
            let report = ReferenceWorldStepReport(solver: reportSolver, candidatePairCount: Int(state.work.x),
                generatedContactCount: Int(state.work.y), persistentContactCount: resultContacts.count,
                toiTestCount: Int(state.work.z), sideCorrectionCount: Int(state.events.x), ccdBudgetExhaustionCount: Int(state.work.w),
                centerGuardCount: Int(state.events.x), generatedContourPointCount: pointCount, eventGroupCount: Int(state.events.y),
                solverSubstepCount: Int(state.events.z), didReachEventGroupLimit: state.events.w != 0,
                predictionMilliseconds: 0, broadPhaseMilliseconds: 0, contactMilliseconds: 0,
                solverMilliseconds: gpuTime, totalMilliseconds: elapsed, hasNonFiniteState: flags & 4 != 0)
            return .init(bubbles: resultBubbles, contacts: resultContacts, contours: resultContours,
                renderData: values(render, count: n, type: SIMD4<Float>.self), report: report,
                telemetry: .init(backend: .metal, frameMilliseconds: elapsed, gpuMilliseconds: gpuTime,
                    finalResidual: reportSolver.finalResidualNorm, newtonIterations: reportSolver.iterations,
                    pcgIterations: reportSolver.pcgIterationCount, didOverflow: didOverflow,
                    didEncounterNonFinite: report.hasNonFiniteState))
        }
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

extension ReferenceMetalSolver: ReferenceMetalFrameExecuting {}
