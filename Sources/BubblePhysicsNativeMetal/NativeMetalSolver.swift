import Foundation
import Metal
import BubblePhysicsModel

package enum NativeMetalSolverError: Error {
    case resourceUnavailable, allocationFailed, commandSetupFailed, commandFailed(String), invalidSnapshot, capacityOverflow
}

package struct NativeMetalCommandTiming {
    package let gpuMilliseconds: Double
    package init(gpuMilliseconds: Double) { self.gpuMilliseconds = gpuMilliseconds }
}

/// Opcjonalny odczyt granic potoku używany wyłącznie przez probe diagnostyczny.
struct NativeMetalStageDiagnostics: Equatable {
    let postSolverPositions: [SIMD2<Float>]
    let postGuardPositions: [SIMD2<Float>]
}

@MainActor
package protocol NativeMetalCommandExecuting {
    // Wywoływane tylko po zakończeniu wszystkich encoderów danej klatki.
    func complete(_ command: MTLCommandBuffer) async throws -> NativeMetalCommandTiming
}

@MainActor
struct NativeMetalCommandExecutor: NativeMetalCommandExecuting {
    func complete(_ command: MTLCommandBuffer) async throws -> NativeMetalCommandTiming {
        try await withCheckedThrowingContinuation { continuation in
            command.addCompletedHandler { completed in
                guard completed.status == .completed else {
                    continuation.resume(throwing: NativeMetalSolverError.commandFailed(
                        completed.error?.localizedDescription ?? "Metal status \(completed.status.rawValue)"))
                    return
                }
                let duration = max(0, completed.gpuEndTime - completed.gpuStartTime) * 1_000
                continuation.resume(returning: NativeMetalCommandTiming(gpuMilliseconds: duration))
            }
            command.commit()
        }
    }
}

@MainActor
final class NativeMetalPersistentState {
    let bubbleCapacity: Int
    let segmentCapacity: Int
    let bubblesPing: MTLBuffer
    let bubblesPong: MTLBuffer
    let contactCapacity: Int
    let cachePing: MTLBuffer
    let cachePong: MTLBuffer
    let contacts: MTLBuffer
    let candidates: MTLBuffer
    let candidateRows: MTLBuffer
    let candidateRowCounts: MTLBuffer
    let grid: MTLBuffer
    let contactControl: MTLBuffer
    let invalidations: MTLBuffer
    let activeContacts: MTLBuffer
    let mergedCache: MTLBuffer
    let scanValues: MTLBuffer
    let scanOffsets: MTLBuffer
    let scanBlockSums: [MTLBuffer]
    let scanBlockOffsets: [MTLBuffer]
    let scanCapacity: Int
    let dispatchStatistics: MTLBuffer
    let indirectArguments: MTLBuffer
    var contactCache: MTLBuffer { publishedIsPing ? cachePing : cachePong }
    var workingCache: MTLBuffer { publishedIsPing ? cachePong : cachePing }
    var publishedCacheCount = 0
    let scratch: MTLBuffer
    let solverPositionsPing: MTLBuffer
    let solverPositionsPong: MTLBuffer
    let diagnosticPostSolverPositions: MTLBuffer?
    let diagnosticPostGuardPositions: MTLBuffer?
    let adjacency: MTLBuffer
    /// uint4 na krok: x = pary odrzucone przez limit k lub pojemność, y = największe zapotrzebowanie na obiekt.
    let candidateOverflow: MTLBuffer
    let adjacencyCounts: MTLBuffer
    let contactEndpoints: MTLBuffer
    let contactCorrections: MTLBuffer
    let solverControl: MTLBuffer
    let guardedBubbles: MTLBuffer
    let safetyControl: MTLBuffer
    let containmentRepairActive: MTLBuffer
    let segmentsPing: MTLBuffer
    let segmentsPong: MTLBuffer
    let bubbleUpdates: MTLBuffer
    let segmentUpdates: MTLBuffer
    let control: MTLBuffer
    let renderPackets: MTLBuffer
    let contourStride: Int
    let deformationPing: MTLBuffer
    let deformationPong: MTLBuffer
    let contourCountsPing: MTLBuffer
    let contourCountsPong: MTLBuffer
    let contourScratch: MTLBuffer
    let contourPointsPing: MTLBuffer
    let contourPointsPong: MTLBuffer
    var publishedContourPoints: MTLBuffer { publishedIsPing ? contourPointsPing : contourPointsPong }
    var workingContourPoints: MTLBuffer { publishedIsPing ? contourPointsPong : contourPointsPing }
    let contourControl: MTLBuffer
    let eventCapacity: Int
    let eventCount: MTLBuffer
    let eventRecords: MTLBuffer
    var publishedDeformation: MTLBuffer { publishedIsPing ? deformationPing : deformationPong }
    var workingDeformation: MTLBuffer { publishedIsPing ? deformationPong : deformationPing }
    var publishedContourCounts: MTLBuffer { publishedIsPing ? contourCountsPing : contourCountsPong }
    var workingContourCounts: MTLBuffer { publishedIsPing ? contourCountsPong : contourCountsPing }
    private var publishedIsPing = true
    var publishedBubbles: MTLBuffer { publishedIsPing ? bubblesPing : bubblesPong }
    var workingBubbles: MTLBuffer { publishedIsPing ? bubblesPong : bubblesPing }
    var segments: MTLBuffer { publishedIsPing ? segmentsPing : segmentsPong }
    var workingSegments: MTLBuffer { publishedIsPing ? segmentsPong : segmentsPing }

    init(device: MTLDevice, bubbleCount: Int, segmentCount: Int, candidateCapacity: Int? = nil,
         contourStride: Int = 64, stageDiagnosticsEnabled: Bool = false, eventCapacity: Int = 1) throws {
        func capacity(_ count: Int) throws -> Int {
            guard count >= 0 else { throw NativeMetalSolverError.allocationFailed }
            var value = 16
            while value < count {
                guard value <= Int.max / 2 else { throw NativeMetalSolverError.allocationFailed }
                value *= 2
            }
            return value
        }
        bubbleCapacity = try capacity(bubbleCount)
        segmentCapacity = try capacity(segmentCount)
        self.contourStride = contourStride
        guard eventCapacity > 0, eventCapacity <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
        self.eventCapacity = eventCapacity
        func buffer(_ name: String, _ count: Int, _ stride: Int) throws -> MTLBuffer {
            let (length, overflow) = count.multipliedReportingOverflow(by: stride)
            guard !overflow, length <= device.maxBufferLength,
                  let value = device.makeBuffer(length: length, options: .storageModeShared)
            else { throw NativeMetalSolverError.allocationFailed }
            value.label = "native.\(name)"
            memset(value.contents(), 0, length)
            return value
        }
        bubblesPing = try buffer("bubbles.ping", bubbleCapacity, MemoryLayout<NativeMetalBubble>.stride)
        bubblesPong = try buffer("bubbles.pong", bubbleCapacity, MemoryLayout<NativeMetalBubble>.stride)
        bubbleUpdates = try buffer("bubbleUpdates", bubbleCapacity, MemoryLayout<NativeMetalBubble>.stride)
        segmentsPing = try buffer("segments.ping", segmentCapacity, MemoryLayout<NativeMetalSegment>.stride)
        segmentsPong = try buffer("segments.pong", segmentCapacity, MemoryLayout<NativeMetalSegment>.stride)
        segmentUpdates = try buffer("segmentUpdates", segmentCapacity, MemoryLayout<NativeMetalSegment>.stride)
        let (rowStride, strideOverflow) = bubbleCapacity.addingReportingOverflow(segmentCapacity)
        // Wiersz kandydatów i wiersz sąsiedztwa ma stałą długość k na obiekt, więc pamięć kontaktów rośnie liniowo.
        let (rowCapacity, rowOverflow) = bubbleCapacity.multipliedReportingOverflow(by: NativeMetalSolver.candidateLimitPerObject)
        guard !strideOverflow, !rowOverflow, rowCapacity <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
        contactCapacity = max(1, candidateCapacity ?? rowCapacity)
        guard contactCapacity <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
        cachePing = try buffer("cache.ping", contactCapacity, MemoryLayout<NativeContactCacheRecord>.stride)
        cachePong = try buffer("cache.pong", contactCapacity, MemoryLayout<NativeContactCacheRecord>.stride)
        contacts = try buffer("contacts", contactCapacity, MemoryLayout<NativeContactCacheRecord>.stride)
        candidates = try buffer("candidates", contactCapacity, MemoryLayout<NativeMetalCandidate>.stride)
        candidateRows = try buffer("candidateRows", rowCapacity, MemoryLayout<NativeMetalCandidate>.stride)
        candidateRowCounts = try buffer("candidateRowCounts", bubbleCapacity * 2, MemoryLayout<UInt32>.stride)
        grid = try buffer("grid", bubbleCapacity, MemoryLayout<NativeMetalGridEntry>.stride)
        contactControl = try buffer("contactControl", 1, MemoryLayout<NativeMetalContactControl>.stride)
        invalidations = try buffer("invalidations", rowStride, MemoryLayout<SIMD2<Int64>>.stride)
        let (mergedCapacity, mergedOverflow) = contactCapacity.multipliedReportingOverflow(by: 2)
        guard !mergedOverflow, mergedCapacity <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
        scanCapacity = max(mergedCapacity, bubbleCapacity * 2)
        activeContacts = try buffer("activeContacts", contactCapacity, MemoryLayout<NativeContactCacheRecord>.stride)
        mergedCache = try buffer("mergedCache", mergedCapacity, MemoryLayout<NativeContactCacheRecord>.stride)
        scanValues = try buffer("scanValues", scanCapacity, MemoryLayout<SIMD4<UInt32>>.stride)
        scanOffsets = try buffer("scanOffsets", scanCapacity, MemoryLayout<SIMD4<UInt32>>.stride)
        var sums: [MTLBuffer] = [], offsets: [MTLBuffer] = []
        var scanCount = scanCapacity
        repeat {
            scanCount = (scanCount + 255) / 256
            sums.append(try buffer("scanBlockSums.\(sums.count)", scanCount, MemoryLayout<SIMD4<UInt32>>.stride))
            offsets.append(try buffer("scanBlockOffsets.\(offsets.count)", scanCount, MemoryLayout<SIMD4<UInt32>>.stride))
        } while scanCount > 1
        scanBlockSums = sums
        scanBlockOffsets = offsets
        indirectArguments = try buffer("indirectArguments", 5 + sums.count * 2, MemoryLayout<SIMD4<UInt32>>.stride)
        dispatchStatistics = try buffer("dispatchStatistics", 3, MemoryLayout<SIMD4<UInt32>>.stride)
        scratch = try buffer("scratch", bubbleCapacity, MemoryLayout<SIMD4<Float>>.stride)
        solverPositionsPing = try buffer("solver.positions.ping", bubbleCapacity, MemoryLayout<SIMD4<Float>>.stride)
        solverPositionsPong = try buffer("solver.positions.pong", bubbleCapacity, MemoryLayout<SIMD4<Float>>.stride)
        if stageDiagnosticsEnabled {
            diagnosticPostSolverPositions = try buffer("diagnostics.postSolver", bubbleCapacity, MemoryLayout<SIMD2<Float>>.stride)
            diagnosticPostGuardPositions = try buffer("diagnostics.postGuard", bubbleCapacity, MemoryLayout<SIMD2<Float>>.stride)
        } else {
            diagnosticPostSolverPositions = nil
            diagnosticPostGuardPositions = nil
        }
        adjacency = try buffer("solver.adjacency", rowCapacity, MemoryLayout<SIMD4<UInt32>>.stride)
        candidateOverflow = try buffer("candidateOverflow", 1, MemoryLayout<SIMD4<UInt32>>.stride)
        adjacencyCounts = try buffer("solver.adjacencyCounts", bubbleCapacity, MemoryLayout<UInt32>.stride)
        contactEndpoints = try buffer("solver.endpoints", contactCapacity, MemoryLayout<SIMD4<UInt32>>.stride)
        contactCorrections = try buffer("solver.corrections", contactCapacity, MemoryLayout<SIMD4<Float>>.stride)
        solverControl = try buffer("solver.control", 1, MemoryLayout<NativeMetalSolverControl>.stride)
        guardedBubbles = try buffer("safety.guardedBubbles", bubbleCapacity, MemoryLayout<UInt32>.stride)
        safetyControl = try buffer("safety.control", 1, MemoryLayout<NativeMetalSafetyControl>.stride)
        containmentRepairActive = try buffer("safety.containmentRepairActive", 9, MemoryLayout<UInt32>.stride)
        renderPackets = try buffer("renderPackets", bubbleCapacity, MemoryLayout<NativeMetalRenderPacket>.stride)
        let (pointCapacity, pointOverflow) = bubbleCapacity.multipliedReportingOverflow(by: contourStride)
        guard !pointOverflow, pointCapacity <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
        deformationPing = try buffer("contour.deformation.ping", pointCapacity, MemoryLayout<SIMD4<Float>>.stride)
        deformationPong = try buffer("contour.deformation.pong", pointCapacity, MemoryLayout<SIMD4<Float>>.stride)
        contourScratch = try buffer("contour.scratch", pointCapacity, MemoryLayout<SIMD4<Float>>.stride)
        contourPointsPing = try buffer("contour.points.ping", pointCapacity, MemoryLayout<SIMD2<Float>>.stride)
        contourPointsPong = try buffer("contour.points.pong", pointCapacity, MemoryLayout<SIMD2<Float>>.stride)
        contourCountsPing = try buffer("contour.counts.ping", bubbleCapacity, MemoryLayout<UInt32>.stride)
        contourCountsPong = try buffer("contour.counts.pong", bubbleCapacity, MemoryLayout<UInt32>.stride)
        contourControl = try buffer("contour.control", 1, MemoryLayout<NativeMetalContourControl>.stride)
        control = try buffer("control", 1, MemoryLayout<NativeMetalControl>.stride)
        eventCount = try buffer("eventCount", 1, MemoryLayout<UInt32>.stride)
        eventRecords = try buffer("eventRecords", eventCapacity, MemoryLayout<NativeMetalEventRecord>.stride)
    }

    func publish() { publishedIsPing.toggle() }
}

/// Trwały stan GPU i solver Jacobi; publikacja świata czeka na guardy oraz CCD.
@MainActor
package final class NativeMetalSolver: NativeMetalFrameExecuting {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let predict: MTLComputePipelineState
    private let pipelines: [String: MTLComputePipelineState]
    private let configuration: NativeMetalConfiguration
    private let candidateCapacity: Int?
    private let collectDispatchStatistics: Bool
    private let collectStageDiagnostics: Bool
    private let commandExecutor: any NativeMetalCommandExecuting
    private var inFlight = false
    private var lastSnapshot: NativeMetalSnapshot?
    private var frameNumber: UInt32 = 0
    private let sensorScratch = NativeMetalSensorScratch()
    private var previousSensorPairs: MTLBuffer?
    private var previousSensorPairCount = 0
    private var previousPolygonSensorPairs: MTLBuffer?
    private var previousPolygonSensorPairCount = 0
    var hasSensorPairHistory: Bool { previousSensorPairCount > 0 || previousPolygonSensorPairCount > 0 }
    private let rigidState: NativeRigidPolygonState
    private let jointState: NativeJointState
    private(set) var publishedPolygons: [ObjectID: NativePublicObject] = [:]
    private(set) var publishedDriveContacts: [ObjectID: [DriveBlockingContact]] = [:]
    /// Kontakty brył ostatniego kroku z sumą normalnych Δλ (zdarzenia kontaktu w `NativePublicWorld`).
    private(set) var publishedRigidContacts: [NativeRigidPolygonState.ContactRecord] = []
    private(set) var removedPolygons: Set<ObjectID> = []
    private(set) var wrappedPolygons: Set<ObjectID> = []
    private(set) var cachedContacts: [NativeContactCacheRecord] = []
    private var publishedCandidateCount = 0
    /// Klucze kandydatów ostatniej publikacji, czytane z bufora dopiero na żądanie (szew testów; klatka ich nie kopiuje).
    var candidateKeys: [NativeContactKey] {
        guard publishedCandidateCount > 0, let buffer = persistentState?.candidates else { return [] }
        let records = buffer.contents().bindMemory(to: NativeMetalCandidate.self, capacity: publishedCandidateCount)
        return (0..<publishedCandidateCount).map { records[$0].key }
    }
    private(set) var persistentState: NativeMetalPersistentState?
    package private(set) var publishedSolverFrame: NativeSolverFrame?
    private(set) var publishedRenderHandoff: NativeMetalRenderHandoff?
    private(set) var publishedContourCPUReadbackCount = 0
    private(set) var stageDiagnostics: NativeMetalStageDiagnostics?

    /// Limit k kandydatów kontaktu na obiekt, wspólny dla baniek, odcinków i brył (zadanie 14: k = 48; zadanie 32: k = 128, bo wiersz statycznej ściany scena mieszana wypełnia wszystkimi bryłami w zasięgu).
    package static let candidateLimitPerObject = 128

    /// Suma długości buforów związanych z kontaktami; 0 przed pierwszym krokiem.
    var contactMemoryBytes: Int {
        guard let s = persistentState else { return 0 }
        let buffers: [MTLBuffer] = [s.cachePing, s.cachePong, s.contacts, s.candidates, s.candidateRows, s.activeContacts,
            s.mergedCache, s.scanValues, s.scanOffsets, s.adjacency, s.contactEndpoints,
            s.contactCorrections]
        return buffers.reduce(0) { $0 + $1.length }
    }
    var rigidContactMemoryBytes: Int { rigidState.contactMemoryBytes }

    package init(device: MTLDevice, commandExecutor: (any NativeMetalCommandExecuting)? = nil,
         configuration: NativeMetalConfiguration = .default, candidateCapacity: Int? = nil,
         collectDispatchStatistics: Bool = false, collectStageDiagnostics: Bool = false) throws {
        self.device = device
        self.rigidState = NativeRigidPolygonState(device: device)
        self.jointState = NativeJointState(device: device)
        self.configuration = configuration.sanitized
        self.candidateCapacity = candidateCapacity
        self.collectDispatchStatistics = collectDispatchStatistics
        self.collectStageDiagnostics = collectStageDiagnostics
        self.commandExecutor = commandExecutor ?? NativeMetalCommandExecutor()
        guard let queue = device.makeCommandQueue() else { throw NativeMetalSolverError.resourceUnavailable }
        self.queue = queue
        let compiled = try NativeMetalPipelineCache.pipelines(for: device)
        predict = compiled.predict
        pipelines = compiled.stages
    }

    /// Rdzeń kroku: neutralne wejście, neutralny wynik. Poprzednia klatka pochodzi z trwałego stanu solvera.
    package func executeFrame(input: NativeSolverInput, scenarioStep: Int) async throws -> NativeSolverFrame {
        try await executeFrame(input: input, scenarioStep: scenarioStep, commandBuffer: nil, beforeCommit: nil)
    }

    func executeFrame(input: NativeSolverInput, scenarioStep: Int,
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff) throws -> Void)?) async throws -> NativeSolverFrame {
        try await executeSnapshot(.init(input: input, previous: lastSnapshot), scenarioStep: scenarioStep,
                                  commandBuffer: commandBuffer, beforeCommit: beforeCommit)
    }

    // Runner potwierdza, że świat gry otrzymał wynik. Bez potwierdzenia zachowujemy
    // kontrakt bezpośredniego solvera: niezmienione wejście kontynuuje trwały stan GPU.
    package func acknowledgePublication() {
        if let publishedSolverFrame { lastSnapshot?.sourceBubbles = publishedSolverFrame.bubbles }
    }

    package func executeSnapshot(_ snapshot: NativeMetalSnapshot, scenarioStep: Int,
                                 commandBuffer: MTLCommandBuffer? = nil,
                                 beforeCommit: ((NativeMetalRenderHandoff) throws -> Void)? = nil) async throws -> NativeSolverFrame {
        guard !inFlight else { throw NativeMetalWorldError.frameInFlight }
        inFlight = true
        defer { inFlight = false }
        stageDiagnostics = nil
        let encodingStart = DispatchTime.now().uptimeNanoseconds
        let count = snapshot.sourceBubbles.count
        let segmentCount = snapshot.sourceSegments.count
        try rigidState.prepare(snapshot.publicSettings?.rigidPolygons ?? [], bubbleCount: count,
            timeStep: snapshot.configuration.timeStep)
        let joints = snapshot.publicSettings?.joints ?? []
        if joints.isEmpty {
            // Bez więzów lista identyfikatorów i słownik encji nie są potrzebne, wystarczą liczby.
            try jointState.prepareWithoutJoints(bubbleCount: count,
                bodyCount: snapshot.publicSettings?.rigidPolygons.count ?? 0, iterations: configuration.solverIterationCount)
        } else {
            try jointState.prepare(joints,
                bubbleIDs: snapshot.sourceBubbles.map { ObjectID(rawValue: UInt64(bitPattern: Int64($0.id.rawValue))) },
                bodyIDs: (snapshot.publicSettings?.rigidPolygons ?? []).map { $0.object.descriptor.id },
                iterations: configuration.solverIterationCount)
        }
        let hasJoints = jointState.count > 0
        let hasRigidBodies = snapshot.publicSettings?.rigidPolygons.contains { $0.object.motionRole != .static || $0.hasRoundCore } == true
        guard frameNumber < UInt32.max else { throw NativeMetalSolverError.invalidSnapshot }
        let nextFrame = frameNumber + 1
        let contourConfiguration = snapshot.configuration.sanitized
        let requiredPoints = snapshot.sourceBubbles.map {
            max(64, ceil(4 * Double.pi * Double($0.targetRadius) / Double(contourConfiguration.maxContourSegmentLength)))
        }.max() ?? 64
        guard requiredPoints.isFinite, requiredPoints <= Double(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
        let requiredContourStride = Int(requiredPoints)
        let requestedEventCapacity = snapshot.publicSettings?.eventBufferCapacity ?? 1
        guard requestedEventCapacity > 0, requestedEventCapacity <= Int(UInt32.max) else {
            throw NativeMetalSolverError.allocationFailed
        }
        guard count <= Int(UInt32.max), segmentCount <= Int(UInt32.max),
              snapshot.previousBubbles == nil || (snapshot.previousBubbles == lastSnapshot?.sourceBubbles
                  && snapshot.previousSegments == lastSnapshot?.sourceSegments)
        else { throw NativeMetalSolverError.invalidSnapshot }

        // Każda alokacja odbywa się przed utworzeniem command buffera.
        let state: NativeMetalPersistentState
        if let existing = persistentState, existing.bubbleCapacity >= count, existing.segmentCapacity >= segmentCount,
           existing.contourStride >= requiredContourStride, existing.eventCapacity >= requestedEventCapacity {
            state = existing
        } else {
            state = try NativeMetalPersistentState(device: device,
                bubbleCount: max(count, persistentState?.bubbleCapacity ?? 0),
                segmentCount: max(segmentCount, persistentState?.segmentCapacity ?? 0), candidateCapacity: candidateCapacity,
                contourStride: max(requiredContourStride, persistentState?.contourStride ?? 64),
                stageDiagnosticsEnabled: collectStageDiagnostics,
                eventCapacity: max(requestedEventCapacity, persistentState?.eventCapacity ?? 1))
            if let previous = persistentState {
                // Nie ma klatki w locie. Kopiujemy ukończony stan do nowych shared buffers.
                memcpy(state.publishedBubbles.contents(), previous.publishedBubbles.contents(),
                       min(state.publishedBubbles.length, previous.publishedBubbles.length))
                memcpy(state.contactCache.contents(), previous.contactCache.contents(),
                       min(state.contactCache.length, previous.contactCache.length))
                state.publishedCacheCount = previous.publishedCacheCount
                memcpy(state.segments.contents(), previous.segments.contents(),
                       min(state.segments.length, previous.segments.length))
                memcpy(state.publishedContourCounts.contents(), previous.publishedContourCounts.contents(),
                       previous.publishedContourCounts.length)
                // Opublikowane kontury (t−1 po następnej publikacji) bańka po bańce, bo krok konturu mógł się zmienić.
                for index in 0..<previous.bubbleCapacity {
                    memcpy(state.publishedContourPoints.contents().advanced(by: index * state.contourStride * 8),
                           previous.publishedContourPoints.contents().advanced(by: index * previous.contourStride * 8),
                           previous.contourStride * 8)
                }
                for index in 0..<previous.bubbleCapacity {
                    memcpy(state.publishedDeformation.contents().advanced(by: index * state.contourStride * 16),
                           previous.publishedDeformation.contents().advanced(by: index * previous.contourStride * 16),
                           previous.contourStride * 16)
                }
            }
        }
        let bubbleStride = MemoryLayout<NativeMetalBubble>.stride
        let segmentStride = MemoryLayout<NativeMetalSegment>.stride
        for change in snapshot.bubbleChanges {
            state.bubbleUpdates.contents().advanced(by: change.index * bubbleStride).storeBytes(of: change.value, as: NativeMetalBubble.self)
        }
        for change in snapshot.segmentChanges {
            state.segmentUpdates.contents().advanced(by: change.index * segmentStride).storeBytes(of: change.value, as: NativeMetalSegment.self)
        }
        var parameters = NativeMetalControl(counts: SIMD4(UInt32(count), UInt32(segmentCount), UInt32(truncatingIfNeeded: scenarioStep), 0),
            physics: SIMD4(snapshot.configuration.timeStep, snapshot.configuration.linearDamping,
                           snapshot.configuration.angularDamping, snapshot.configuration.contactStiffness),
            contactDamping: SIMD4(snapshot.configuration.contactDamping, 0, 0, 0))
        if let region = snapshot.publicSettings?.region {
            parameters.region = SIMD4(region.min.x, region.min.y, region.max.x, region.max.y)
        }
        state.control.contents().storeBytes(of: parameters, as: NativeMetalControl.self)
        var contourParameters = NativeMetalContourControl(
            counts: SIMD4(UInt32(state.contourStride), UInt32(lastSnapshot?.sourceBubbles.count ?? 0), 0, 0),
            shape: SIMD4(contourConfiguration.maxContourSegmentLength, contourConfiguration.deformationRecoveryRate,
                         contourConfiguration.contourSurfaceTension, contourConfiguration.positionTolerance))
        let solverParameters = NativeMetalSolverControl(
            counts: SIMD4(1, 0, 0, UInt32(clamping: configuration.solverIterationCount)),
            physics: SIMD4(configuration.contactCompliance / (snapshot.configuration.timeStep * snapshot.configuration.timeStep),
                          snapshot.configuration.positionTolerance, 0, 0))
        state.solverControl.contents().storeBytes(of: solverParameters, as: NativeMetalSolverControl.self)
        state.safetyControl.contents().storeBytes(of: NativeMetalSafetyControl(counts: .zero), as: NativeMetalSafetyControl.self)
        memset(state.containmentRepairActive.contents(), 0, state.containmentRepairActive.length)
        state.containmentRepairActive.contents().storeBytes(of: UInt32(1), as: UInt32.self)
        memset(state.scratch.contents(), 0, state.scratch.length)
        // Wyłącznie zmiany wejścia gry mogą oznaczać teleport; normalna predykcja nie resetuje cache.
        // Poprzedni krok zwykle ma te same obiekty w tej samej kolejności, więc para po indeksie zastępuje słownik;
        // słownik powstaje tylko wtedy, gdy zestaw albo kolejność się zmieniły.
        let previousBubbleList = lastSnapshot?.sourceBubbles ?? []
        let previousSegmentList = lastSnapshot?.sourceSegments ?? []
        let bubblesAligned = previousBubbleList.count == snapshot.sourceBubbles.count
            && zip(previousBubbleList, snapshot.sourceBubbles).allSatisfy { $0.id == $1.id }
        let segmentsAligned = previousSegmentList.count == snapshot.sourceSegments.count
            && zip(previousSegmentList, snapshot.sourceSegments).allSatisfy { $0.id == $1.id }
        let previousBubbles = bubblesAligned ? [:] : Dictionary(uniqueKeysWithValues: previousBubbleList.map { ($0.id, $0) })
        let previousSegments = segmentsAligned ? [:] : Dictionary(uniqueKeysWithValues: previousSegmentList.map { ($0.id, $0) })
        var invalidationRecords: [SIMD2<Int64>] = []
        var teleportedBubbles: Set<Int64> = []
        for (index, bubble) in snapshot.sourceBubbles.enumerated() {
            if let previous = bubblesAligned ? previousBubbleList[index] : previousBubbles[bubble.id],
               (bubble.center - previous.center).euclideanLength > configuration.teleportDistanceMultiplier * bubble.targetRadius {
                invalidationRecords.append(SIMD2(Int64(bubble.id.rawValue), 0))
                teleportedBubbles.insert(Int64(bubble.id.rawValue))
            }
        }
        for (index, segment) in snapshot.sourceSegments.enumerated() {
            if let previous = segmentsAligned ? previousSegmentList[index] : previousSegments[segment.id], previous != segment {
                invalidationRecords.append(SIMD2(Int64(segment.id), 1))
            }
        }
        if let structuralShapes = snapshot.publicSettings?.structuralShapes {
            for id in structuralShapes.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                let value = Int64(bitPattern: id.rawValue)
                if teleportedBubbles.insert(value).inserted {
                    invalidationRecords.append(SIMD2(value, 0))
                }
            }
        }
        for (index, value) in invalidationRecords.enumerated() {
            state.invalidations.contents().advanced(by: index * MemoryLayout<SIMD2<Int64>>.stride).storeBytes(of: value, as: SIMD2<Int64>.self)
        }
        let contactParameters = NativeMetalContactControl(
            limits: SIMD4(nextFrame, UInt32(clamping: configuration.cacheExpiryFrames), UInt32(state.contactCapacity), UInt32(state.publishedCacheCount)),
            counts: .zero, cache: SIMD4(0, 0, UInt32(invalidationRecords.count), UInt32(Self.candidateLimitPerObject)),
            thresholds: SIMD4(configuration.teleportDistanceMultiplier, configuration.ccdVelocityMultiplier,
                              snapshot.configuration.contactTolerance, snapshot.configuration.separationTolerance), cellWidth: .zero)
        state.contactControl.contents().storeBytes(of: contactParameters, as: NativeMetalContactControl.self)
        memset(state.dispatchStatistics.contents(), 0, state.dispatchStatistics.length)
        memset(state.candidateOverflow.contents(), 0, state.candidateOverflow.length)
        state.eventCount.contents().storeBytes(of: UInt32(0), as: UInt32.self)
        state.dispatchStatistics.contents().advanced(by: 16).storeBytes(of: SIMD4<UInt32>(collectDispatchStatistics ? 1 : 0, 0, 0, 0), as: SIMD4<UInt32>.self)

        func eventBuffer<T>(_ values: [T]) throws -> MTLBuffer {
            let (length, overflow) = max(1, values.count).multipliedReportingOverflow(by: MemoryLayout<T>.stride)
            guard !overflow, length <= device.maxBufferLength,
                  let buffer = device.makeBuffer(length: length, options: .storageModeShared)
            else { throw NativeMetalSolverError.allocationFailed }
            if !values.isEmpty { values.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) } }
            return buffer
        }
        var structuralHeaders: [NativeStructuralHeader] = []
        var structuralSources: [NativeStructuralSourceRecord] = []
        var structuralClips: [SIMD4<Float>] = []
        let previousStructuralIndices: [ObjectID: UInt64] = snapshot.publicSettings?.structuralShapes.isEmpty == false
            ? Dictionary(uniqueKeysWithValues: (lastSnapshot?.sourceBubbles ?? []).enumerated().map { index, bubble in
                (ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue))), UInt64(index))
            }) : [:]
        for bubble in snapshot.sourceBubbles {
            let id = ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue)))
            let shape = snapshot.publicSettings?.structuralShapes[id]
            let first = structuralSources.count
            if let shape {
                for source in shape.sources {
                    let clipStart = structuralClips.count
                    structuralClips += source.clips
                    guard clipStart <= Int(UInt32.max), source.clips.count <= Int(UInt32.max),
                          structuralClips.count <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
                    structuralSources.append(.init(identity: SIMD2(source.id.rawValue,
                        previousStructuralIndices[source.id] ?? UInt64.max),
                        geometry: SIMD4(source.center.x, source.center.y, source.radius, 0),
                        clips: SIMD4(UInt32(clipStart), UInt32(source.clips.count), 0, 0)))
                }
            }
            guard first <= Int(UInt32.max), structuralSources.count <= Int(UInt32.max),
                  structuralSources.count - first <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
            structuralHeaders.append(.init(range: SIMD4(UInt32(first), UInt32(structuralSources.count - first), 0, 0),
                origin: SIMD4(shape?.origin.x ?? 0, shape?.origin.y ?? 0, 0, 0)))
        }
        guard structuralSources.count <= Int(UInt32.max), structuralClips.count <= Int(UInt32.max) else {
            throw NativeMetalSolverError.allocationFailed
        }
        // Standardowe klatki nie alokują buforów operacji strukturalnych.
        contourParameters.counts.z = structuralSources.isEmpty ? 0 : 1
        state.contourControl.contents().storeBytes(of: contourParameters, as: NativeMetalContourControl.self)
        let structuralHeaderBuffer = try structuralSources.isEmpty ? state.eventRecords : eventBuffer(structuralHeaders)
        let structuralSourceBuffer = try structuralSources.isEmpty ? state.eventRecords : eventBuffer(structuralSources)
        let structuralClipBuffer = try structuralClips.isEmpty ? state.eventRecords : eventBuffer(structuralClips)
        let sensors = snapshot.publicSettings?.sensors ?? []
        let (pairCount, pairOverflow) = sensors.count.multipliedReportingOverflow(by: count)
        let rigidInputs = snapshot.publicSettings?.rigidPolygons ?? []
        let (polygonPairCount, polygonPairOverflow) = sensors.count.multipliedReportingOverflow(by: rigidInputs.count)
        guard !pairOverflow, !polygonPairOverflow, pairCount <= Int(UInt32.max),
              polygonPairCount <= Int(UInt32.max), pairCount <= Int(UInt32.max) - polygonPairCount,
              sensors.count <= Int(UInt32.max) else {
            throw NativeMetalSolverError.allocationFailed
        }
        var sensorRecords: [NativeMetalSensorRecord] = [], sensorVertices: [SIMD2<Float>] = []
        var sensorAllowed: [UInt32] = []
        var polygonSensorAllowed: [UInt32] = []
        for sensor in sensors {
            let start = sensorVertices.count
            var radius: Float = 0
            switch sensor.geometry.shape {
            case .circle(let value): radius = value
            case .polygon(let polygon): sensorVertices += polygon.vertices
            }
            guard sensorVertices.count <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
            sensorRecords.append(NativeMetalSensorRecord(
                identity: SIMD2(sensor.id.rawValue, sensor.eventInterest.rawValue),
                geometry: SIMD4(sensor.position.x, sensor.position.y, sensor.rotation, radius),
                range: SIMD4(UInt32(start), UInt32(sensorVertices.count - start), 0, 0)))
            for bubble in snapshot.sourceBubbles {
                let id = ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue)))
                sensorAllowed.append(sensor.filter.objectIDs?.contains(id) ?? true ? 1 : 0)
            }
            for polygon in rigidInputs {
                polygonSensorAllowed.append(sensor.filter.objectIDs?.contains(polygon.object.descriptor.id) ?? true ? 1 : 0)
            }
        }
        // Wejścia sensorów używają trwałych buforów: przy kodowaniu nie ma klatki w locie.
        let sensorRecordBuffer = try (sensorRecords.isEmpty ? state.eventRecords : sensorScratch.records.upload(sensorRecords, device: device))
        let sensorVertexBuffer = try (sensorVertices.isEmpty ? state.eventRecords : sensorScratch.vertices.upload(sensorVertices, device: device))
        let sensorAllowedBuffer = try (sensorAllowed.isEmpty ? state.eventRecords : sensorScratch.allowed.upload(sensorAllowed, device: device))
        // Bufory par naprzemienne: pary poprzedniej klatki pozostają nienaruszone aż do publikacji.
        let currentSensorPairs = try (pairCount == 0 ? state.eventRecords : sensorScratch.pairs.next(
            avoiding: previousSensorPairs, zeroedCount: pairCount, of: NativeMetalSensorPair.self, device: device))
        let previousSensorPairBuffer = previousSensorPairs ?? state.eventRecords
        let polygonSensorAllowedBuffer = try (polygonSensorAllowed.isEmpty ? state.eventRecords
            : sensorScratch.polygonAllowed.upload(polygonSensorAllowed, device: device))
        let currentPolygonSensorPairs = try (polygonPairCount == 0 ? state.eventRecords : sensorScratch.polygonPairs.next(
            avoiding: previousPolygonSensorPairs, zeroedCount: polygonPairCount, of: NativeMetalSensorPair.self, device: device))
        let previousPolygonSensorPairBuffer = previousPolygonSensorPairs ?? state.eventRecords

        // Punkty i wyniki hit-testu: bufory na krok, alokowane przed utworzeniem bufora poleceń.
        let hitTestPoints = try snapshot.hitTests.isEmpty ? state.eventRecords : eventBuffer(snapshot.hitTests)
        let hitTestResultBuffer = try snapshot.hitTests.isEmpty ? state.eventRecords
            : eventBuffer([NativeHitTestResult](repeating: .init(identity: 0, layer: 0, found: 0), count: snapshot.hitTests.count))
        // Liczba punktów, liczba brył, stride konturu.
        let hitTestCounts = try snapshot.hitTests.isEmpty ? state.eventRecords : eventBuffer([SIMD4(
            UInt32(snapshot.hitTests.count), UInt32(rigidState.count), UInt32(state.contourStride), UInt32(0))])

        let descriptor = MTLCommandBufferDescriptor()
        descriptor.retainedReferences = true
        descriptor.errorOptions = .encoderExecutionStatus
        guard let command = commandBuffer ?? queue.makeCommandBuffer(descriptor: descriptor),
              command.device === device, command.status == .notEnqueued,
              let blit = command.makeBlitCommandEncoder()
        else { throw NativeMetalSolverError.commandSetupFailed }
        command.label = "native.frame.step.\(scenarioStep)"
        blit.label = "native.inputs"
        if count > 0 {
            blit.copy(from: state.publishedBubbles, sourceOffset: 0, to: state.workingBubbles, destinationOffset: 0, size: count * bubbleStride)
        }
        if segmentCount > 0 {
            blit.copy(from: state.segments, sourceOffset: 0, to: state.workingSegments, destinationOffset: 0, size: segmentCount * segmentStride)
        }
        // Zmiana indeksu po sortowaniu ID nie jest zmianą wejścia CPU.
        // Źródło pozostaje opublikowanym buforem, więc remapy nie kolidują.
        // Zmiana indeksu po sortowaniu ID nie jest zmianą wejścia CPU.
        // Źródło pozostaje opublikowanym buforem, więc remapy nie kolidują.
        // Sąsiednie rekordy są łączone w jedno polecenie kopiowania na ciągły zakres.
        for run in NativeMetalCopyRun.coalesce(snapshot.bubbleRemaps.map { ($0.sourceIndex, $0.destinationIndex) }) {
            blit.copy(from: state.publishedBubbles, sourceOffset: run.source * bubbleStride,
                      to: state.workingBubbles, destinationOffset: run.destination * bubbleStride, size: run.count * bubbleStride)
        }
        for run in NativeMetalCopyRun.coalesce(snapshot.bubbleChanges.map { ($0.index, $0.index) }) {
            blit.copy(from: state.bubbleUpdates, sourceOffset: run.source * bubbleStride,
                      to: state.workingBubbles, destinationOffset: run.destination * bubbleStride, size: run.count * bubbleStride)
        }
        for run in NativeMetalCopyRun.coalesce(snapshot.segmentRemaps.map { ($0.sourceIndex, $0.destinationIndex) }) {
            blit.copy(from: state.segments, sourceOffset: run.source * segmentStride,
                      to: state.workingSegments, destinationOffset: run.destination * segmentStride, size: run.count * segmentStride)
        }
        for run in NativeMetalCopyRun.coalesce(snapshot.segmentChanges.map { ($0.index, $0.index) }) {
            blit.copy(from: state.segmentUpdates, sourceOffset: run.source * segmentStride,
                      to: state.workingSegments, destinationOffset: run.destination * segmentStride, size: run.count * segmentStride)
        }
        rigidState.encodeInputs(blit)
        blit.endEncoding()
        guard let encoder = command.makeComputeCommandEncoder() else { throw NativeMetalSolverError.commandSetupFailed }
        encoder.label = "native.predict"
        encoder.setComputePipelineState(predict)
        encoder.setBuffer(state.workingBubbles, offset: 0, index: 0)
        encoder.setBuffer(state.control, offset: 0, index: 1)
        if count > 0 {
            encoder.dispatchThreads(.init(width: count, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: min(predict.threadExecutionWidth, predict.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        func dispatch(_ name: String, buffers: [MTLBuffer], threads: Int) {
            let pipeline = pipelines[name]!
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            if threads > 0 {
                encoder.dispatchThreads(.init(width: threads, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
            }
        }
        func dispatchReduction(_ name: String, buffers: [MTLBuffer]) {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines[name]!)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
        }
        func prepareIndirectArguments() {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["nativePrepareIndirectArguments"]!)
            for (index, buffer) in [state.control, state.contactControl, state.indirectArguments].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            var levels = UInt32(state.scanBlockSums.count)
            encoder.setBytes(&levels, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.dispatchThreads(.init(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        }
        func dispatchContacts(_ name: String, buffers: [MTLBuffer], argument: Int) {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines[name]!)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.dispatchThreadgroups(indirectBuffer: state.indirectArguments, indirectBufferOffset: argument * 16,
                threadsPerThreadgroup: .init(width: 32, height: 1, depth: 1))
        }
        // Trzystopniowy skan blokowy (dla obecnej pojemności): każdy blok ma 256 work-itemów.
        // Rekurencja skanuje sumy bloków, a osobne dispatchy dodają offsety rodziców.
        func scan(mode: UInt32, maximum: Int) {
            var lengths = [maximum]
            while lengths.last! > 256 { lengths.append((lengths.last! + 255) / 256) }
            for level in lengths.indices {
                encoder.memoryBarrier(scope: .buffers)
                encoder.setComputePipelineState(pipelines["nativeScanBlocks"]!)
                let input = level == 0 ? state.scanValues : state.scanBlockSums[level - 1]
                let output = level == 0 ? state.scanOffsets : state.scanBlockOffsets[level - 1]
                for (i, b) in [input, output, state.scanBlockSums[level], state.control, state.contactControl].enumerated() {
                    encoder.setBuffer(b, offset: 0, index: i)
                }
                var parameters = SIMD2(mode, UInt32(level))
                encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 5)
                if mode == 0 {
                    encoder.dispatchThreadgroups(.init(width: (lengths[level] + 255) / 256, height: 1, depth: 1),
                        threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
                } else {
                    encoder.dispatchThreadgroups(indirectBuffer: state.indirectArguments,
                        indirectBufferOffset: (5 + (Int(mode) - 1) * state.scanBlockSums.count + level) * 16,
                        threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
                }
            }
            if lengths.count > 1 {
                for level in (0..<(lengths.count - 1)).reversed() {
                    encoder.memoryBarrier(scope: .buffers)
                    encoder.setComputePipelineState(pipelines["nativeAddScanBlockOffsets"]!)
                    let output = level == 0 ? state.scanOffsets : state.scanBlockOffsets[level - 1]
                    for (i, b) in [output, state.scanBlockOffsets[level], state.control, state.contactControl].enumerated() {
                        encoder.setBuffer(b, offset: 0, index: i)
                    }
                    var parameters = SIMD2(mode, UInt32(level))
                    encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 4)
                    if mode == 0 {
                        encoder.dispatchThreads(.init(width: lengths[level], height: 1, depth: 1),
                            threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
                    } else {
                        encoder.dispatchThreadgroups(indirectBuffer: state.indirectArguments,
                            indirectBufferOffset: (5 + (Int(mode) - 1) * state.scanBlockSums.count + level) * 16,
                            threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
                    }
                }
            }
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["nativeFinishScan"]!)
            for (i, b) in [state.scanOffsets, state.control, state.contactControl].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
            var parameters = SIMD2(mode, UInt32(0))
            encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
            encoder.setBuffer(state.candidateOverflow, offset: 0, index: 4)
            encoder.dispatchThreads(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        }
        if hasRigidBodies {
            dispatch("nativeRigidPredict", buffers: [rigidState.bodies, rigidState.vertices, rigidState.control,
                state.control, state.workingSegments, state.safetyControl, rigidState.walls, jointState.ranges, jointState.exclusions],
                threads: rigidState.count)
        }
        dispatchReduction("nativePrepareGrid", buffers: [state.workingBubbles, state.control, state.contactControl])
        dispatch("nativeBuildGrid", buffers: [state.workingBubbles, state.control, state.contactControl, state.grid], threads: state.bubbleCapacity)
        var size = 2
        while size <= state.bubbleCapacity {
            var distance = size / 2
            while distance > 0 {
                encoder.memoryBarrier(scope: .buffers)
                let pipeline = pipelines["nativeSortGrid"]!
                encoder.setComputePipelineState(pipeline)
                encoder.setBuffer(state.grid, offset: 0, index: 0)
                var pass = SIMD2(UInt32(size), UInt32(distance))
                encoder.setBytes(&pass, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 1)
                encoder.dispatchThreads(.init(width: state.bubbleCapacity, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
                distance /= 2
            }
            size *= 2
        }
        dispatch("nativeEmitCandidates", buffers: [state.workingBubbles, state.control, state.contactControl,
            state.grid, state.workingSegments, state.candidateRows, state.candidateRowCounts, state.candidateOverflow,
            jointState.ranges, jointState.exclusions], threads: count)
        dispatch("nativePrepareCandidateCounts", buffers: [state.control, state.candidateRowCounts, state.scanValues], threads: count * 2)
        scan(mode: 0, maximum: max(1, count * 2))
        prepareIndirectArguments()
        dispatch("nativeCompactCandidates", buffers: [state.control, state.contactControl, state.candidateRows,
            state.candidateRowCounts, state.candidates, state.scanOffsets, state.dispatchStatistics],
            threads: count * Self.candidateLimitPerObject)
        dispatchContacts("nativeBuildContacts", buffers: [state.workingBubbles, state.workingSegments, state.contactControl,
            state.candidates, state.contacts], argument: 0)
        dispatchContacts("nativePrepareContactFlags", buffers: [state.contacts, state.contactControl, state.scanValues], argument: 0)
        scan(mode: 1, maximum: state.contactCapacity)
        prepareIndirectArguments()
        dispatchContacts("nativeCompactActiveContacts", buffers: [state.contacts, state.activeContacts, state.contactControl, state.scanOffsets], argument: 0)
        dispatchContacts("nativeMatchContactCache", buffers: [state.contactCache, state.activeContacts, state.mergedCache,
            state.contactControl, state.invalidations, state.workingBubbles, state.workingSegments, state.control,
            state.scanValues, state.dispatchStatistics], argument: 1)
        dispatch("nativeRetainContactCache", buffers: [state.contactCache, state.activeContacts, state.mergedCache,
            state.contactControl, state.invalidations, state.workingBubbles, state.workingSegments, state.control,
            state.scanValues, state.dispatchStatistics], threads: state.publishedCacheCount)
        scan(mode: 2, maximum: state.contactCapacity + state.publishedCacheCount)
        dispatchContacts("nativeCompactContactCache", buffers: [state.mergedCache, state.workingCache, state.contactControl,
            state.scanValues, state.scanOffsets, state.dispatchStatistics], argument: 2)
        prepareIndirectArguments()
        dispatch("nativeClearAdjacency", buffers: [state.control, state.adjacencyCounts], threads: count)
        dispatchContacts("nativeEmitAdjacency", buffers: [state.workingBubbles, state.workingSegments, state.workingCache,
            state.control, state.contactControl, state.adjacency, state.contactEndpoints, state.dispatchStatistics,
            state.adjacencyCounts, state.candidateOverflow], argument: 3)
        dispatch("nativeBuildAdjacency", buffers: [state.control, state.contactControl,
            state.adjacency, state.adjacencyCounts, state.candidateOverflow], threads: count)
        dispatchContacts("nativePrepareSolverContacts", buffers: [state.workingBubbles, state.workingSegments, state.workingCache,
            state.control, state.contactControl, state.contactEndpoints, state.adjacencyCounts], argument: 3)
        dispatch("nativeApplyWarmStart", buffers: [state.workingBubbles, state.workingCache, state.control,
            state.contactControl, state.adjacency, state.adjacencyCounts, state.solverPositionsPing], threads: count)
        var inputPositions = state.solverPositionsPing
        var outputPositions = state.solverPositionsPong
        func measureResidual() {
            dispatch("nativeMeasureResidual", buffers: [state.workingBubbles, state.workingSegments, state.workingCache,
                inputPositions, state.control, state.contactControl, state.adjacency, state.adjacencyCounts,
                state.solverControl, state.scratch], threads: count)
            dispatchReduction("nativeReduceSolverResidual", buffers: [state.control, state.solverControl, state.scratch,
                state.dispatchStatistics])
        }
        // Pomiar przed korekcją pozwala warm-startowi zakończyć się bez dodatkowej iteracji.
        measureResidual()
        if hasRigidBodies {
            dispatch("nativeRigidEmitCandidates", buffers: [rigidState.bodies, state.workingBubbles, inputPositions,
                rigidState.control, rigidState.candidates, rigidState.rowCounts, state.candidateOverflow,
                jointState.ranges, jointState.exclusions], threads: rigidState.count)
            // CCD bryła–bryła po wierszach kandydatów, przed pętlą: faza 1 liczy czas uderzenia, faza 2 cofa bryły.
            dispatch("nativeRigidResolveCCD", buffers: [rigidState.bodies, rigidState.vertices, rigidState.triangles,
                rigidState.control, rigidState.candidates, rigidState.rowCounts], threads: rigidState.count)
            dispatch("nativeRigidApplyCCD", buffers: [rigidState.bodies, rigidState.control], threads: rigidState.count)
        }
        for _ in 0..<configuration.solverIterationCount {
            dispatchContacts("nativeUpdateContactMultipliers", buffers: [state.workingBubbles, state.workingSegments,
                state.workingCache, inputPositions, state.control, state.contactControl, state.solverControl,
                state.contactEndpoints, state.adjacencyCounts, state.contactCorrections], argument: 3)
            dispatch("nativeSolveJacobi", buffers: [state.workingBubbles, inputPositions, outputPositions, state.control,
                state.contactControl, state.solverControl, state.adjacency, state.adjacencyCounts,
                state.contactCorrections, state.scratch], threads: count)
            swap(&inputPositions, &outputPositions)
            measureResidual()
            if hasRigidBodies {
                dispatch("nativeRigidContacts", buffers: [rigidState.bodies, rigidState.vertices, rigidState.triangles,
                    state.workingBubbles, inputPositions, rigidState.control, rigidState.contacts,
                    state.safetyControl, rigidState.candidates, rigidState.rowCounts], threads: rigidState.rowCapacity)
                dispatch("nativeRigidApplyBodies", buffers: [rigidState.bodies, rigidState.control, rigidState.contacts,
                    rigidState.candidates, rigidState.rowCounts], threads: rigidState.count)
            }
            if hasJoints {
                dispatch("nativeSolveJoints", buffers: [rigidState.bodies, state.workingBubbles, inputPositions,
                    jointState.records, jointState.corrections, jointState.control, state.control], threads: jointState.count)
                dispatch("nativeApplyJointBodies", buffers: [rigidState.bodies, jointState.corrections,
                    jointState.references, jointState.ranges, jointState.control], threads: rigidState.count)
                dispatch("nativeApplyJointBubbles", buffers: [state.workingBubbles, inputPositions, jointState.corrections,
                    jointState.references, jointState.ranges, jointState.control, state.solverControl], threads: count)
            }
            if hasRigidBodies {
                dispatch("nativeRigidGuardWalls", buffers: [rigidState.bodies, rigidState.vertices, rigidState.triangles, rigidState.control,
                    jointState.ranges, jointState.exclusions], threads: rigidState.count)
                dispatch("nativeRigidApplyBubbles", buffers: [state.workingBubbles, inputPositions, rigidState.control,
                    rigidState.contacts, state.solverControl, rigidState.candidates, rigidState.rowCounts], threads: count)
            }
        }
        if let diagnosticPostSolver = state.diagnosticPostSolverPositions {
            dispatch("nativeCapturePositions", buffers: [inputPositions, diagnosticPostSolver, state.control], threads: count)
        }
        dispatch("nativeFindFastCandidates", buffers: [state.workingBubbles, state.workingSegments,
            state.control, state.contactControl, state.guardedBubbles, state.safetyControl], threads: count)
        dispatch("nativeResolveCCD", buffers: [state.workingBubbles, state.workingSegments, inputPositions,
            state.control, state.contactControl, state.guardedBubbles, state.safetyControl, state.dispatchStatistics], threads: count)
        dispatch("nativeApplyCenterGuards", buffers: [state.workingBubbles, state.workingSegments, inputPositions,
            state.control, state.contactControl, state.guardedBubbles, state.safetyControl, state.dispatchStatistics],
            threads: count)
        // Bounded GPU repair of pairs introduced by CCD/obstacle projection.
        // Every repair rechecks obstacle invariants, in the same command buffer.
        for pass in 0..<8 {
            encoder.memoryBarrier(scope: .buffers)
            let pipeline = pipelines["nativeSeparateContainedBubbles"]!
            encoder.setComputePipelineState(pipeline)
            encoder.setThreadgroupMemoryLength(pipeline.threadExecutionWidth * MemoryLayout<SIMD2<Float>>.stride, index: 0)
            for (index, buffer) in [state.workingBubbles, inputPositions, outputPositions,
                state.control, state.solverControl, state.guardedBubbles, state.safetyControl,
                state.containmentRepairActive].enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            var repairPass = UInt32(pass)
            encoder.setBytes(&repairPass, length: MemoryLayout<UInt32>.stride, index: 8)
            if count > 0 {
                encoder.dispatchThreadgroups(.init(width: count, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
            }
            swap(&inputPositions, &outputPositions)
            dispatch("nativeReapplyCenterGuards", buffers: [state.workingBubbles, state.workingSegments, inputPositions,
                state.control, state.contactControl, state.guardedBubbles, state.safetyControl, state.dispatchStatistics],
                threads: count)
        }
        dispatch("nativeValidateBubbleContainment", buffers: [state.workingBubbles, inputPositions,
            state.control, state.solverControl, state.safetyControl], threads: count * count)
        if let diagnosticPostGuard = state.diagnosticPostGuardPositions {
            dispatch("nativeCapturePositions", buffers: [inputPositions, diagnosticPostGuard, state.control], threads: count)
        }
        dispatchContacts("nativeFinalizeSolverContacts", buffers: [state.workingBubbles, state.workingSegments,
            state.workingCache, inputPositions, state.contactControl, state.contactEndpoints], argument: 3)
        if snapshot.publicSettings != nil {
            encoder.memoryBarrier(scope: .buffers)
            let pipeline = pipelines["nativeCompactMergeEvents"]!
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in [state.workingBubbles, state.workingCache, state.control,
                                    state.contactControl, state.eventCount, state.eventRecords].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            var capacity = UInt32(requestedEventCapacity)
            encoder.setBytes(&capacity, length: MemoryLayout<UInt32>.stride, index: 6)
            encoder.dispatchThreads(.init(width: state.contactCapacity, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
                                             height: 1, depth: 1))
        }
        dispatch("nativeUpdateVelocities", buffers: [state.workingBubbles, inputPositions, state.control], threads: count)
        dispatch("nativeDampContactNormalMotion", buffers: [state.workingBubbles, state.workingSegments,
            state.workingCache, state.control, state.contactControl, state.adjacency, state.adjacencyCounts], threads: count)
        dispatchContacts("nativeInvalidateSafetyCache", buffers: [state.workingBubbles, state.workingCache,
            state.control, state.contactControl, state.guardedBubbles, state.safetyControl], argument: 3)
        dispatchContacts("nativeCheckFinite", buffers: [state.workingBubbles, state.workingSegments, state.workingCache,
            state.control, state.contactControl, state.solverControl, state.safetyControl],
            argument: 4)
        dispatch("nativeAccumulateContactPressure", buffers: [state.workingBubbles, state.workingSegments,
            state.workingCache, state.control, state.contactControl, state.contourControl, state.publishedBubbles,
            state.publishedDeformation, state.publishedContourCounts, state.contourScratch, state.workingContourCounts,
            state.adjacency, state.adjacencyCounts, state.safetyControl, structuralHeaderBuffer],
            threads: count * state.contourStride)
        if !structuralSources.isEmpty {
            dispatch("nativeSeedStructuralContours", buffers: [state.workingBubbles, structuralHeaderBuffer,
                structuralSourceBuffer, structuralClipBuffer, state.contourScratch, state.workingContourCounts,
                state.control, state.contourControl, state.safetyControl, state.publishedBubbles,
                state.publishedDeformation, state.publishedContourCounts], threads: count * state.contourStride)
        }
        var contourInput = state.contourScratch
        var contourOutput = state.workingDeformation
        // Liczba nieparzysta: wynik pozostaje w roboczym buforze ping-pong.
        for _ in 0..<13 {
            dispatch("nativeGenerateContours", buffers: [contourInput, contourOutput, state.workingContourCounts,
                state.control, state.contourControl, state.safetyControl], threads: count * state.contourStride)
            swap(&contourInput, &contourOutput)
        }
        dispatch("nativePrepareRenderData", buffers: [state.workingBubbles, state.workingDeformation,
            state.workingContourCounts, state.workingContourPoints, state.renderPackets, state.control,
            state.contourControl, state.safetyControl], threads: count)
        if snapshot.publicSettings != nil {
            dispatch("nativeApplyPublicRegion", buffers: [state.workingBubbles, state.workingContourPoints,
                state.renderPackets, state.workingContourCounts, state.control, state.contourControl, state.safetyControl], threads: count)
            dispatchContacts("nativeInvalidateRegionCache", buffers: [state.workingBubbles, state.workingCache,
                state.control, state.contactControl], argument: 3)
            if pairCount > 0 {
                encoder.memoryBarrier(scope: .buffers)
                let pipeline = pipelines["nativeCompactSensorEvents"]!
                encoder.setComputePipelineState(pipeline)
                for (index, buffer) in [state.workingBubbles, state.control, sensorRecordBuffer,
                    sensorVertexBuffer, sensorAllowedBuffer, previousSensorPairBuffer,
                    currentSensorPairs, state.eventCount, state.eventRecords].enumerated() {
                    encoder.setBuffer(buffer, offset: 0, index: index)
                }
                var sensorSettings = SIMD4(UInt32(sensors.count), UInt32(previousSensorPairCount),
                                           UInt32(requestedEventCapacity), UInt32(0))
                encoder.setBytes(&sensorSettings, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 9)
                encoder.dispatchThreads(.init(width: pairCount, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
                                                 height: 1, depth: 1))
            }
            if previousSensorPairCount > 0 {
                encoder.memoryBarrier(scope: .buffers)
                let pipeline = pipelines["nativeCompactMissingSensorEvents"]!
                encoder.setComputePipelineState(pipeline)
                for (index, buffer) in [previousSensorPairBuffer, currentSensorPairs,
                    state.eventCount, state.eventRecords].enumerated() {
                    encoder.setBuffer(buffer, offset: 0, index: index)
                }
                var settings = SIMD4(UInt32(previousSensorPairCount), UInt32(pairCount),
                                     UInt32(requestedEventCapacity), UInt32(0))
                encoder.setBytes(&settings, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
                encoder.dispatchThreads(.init(width: previousSensorPairCount, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
                                                 height: 1, depth: 1))
            }
        }
        if hasRigidBodies {
            dispatch("nativeRigidFinish", buffers: [rigidState.bodies, rigidState.vertices, rigidState.control,
                state.control, state.safetyControl], threads: rigidState.count)
        }
        if polygonPairCount > 0 {
            encoder.memoryBarrier(scope: .buffers)
            let pipeline = pipelines["nativeCompactPolygonSensorEvents"]!
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in [rigidState.bodies, rigidState.vertices, sensorRecordBuffer,
                sensorVertexBuffer, polygonSensorAllowedBuffer, previousPolygonSensorPairBuffer,
                currentPolygonSensorPairs, state.eventCount, state.eventRecords].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            var sensorSettings = SIMD4(UInt32(sensors.count), UInt32(previousPolygonSensorPairCount),
                                       UInt32(requestedEventCapacity), UInt32(rigidInputs.count))
            encoder.setBytes(&sensorSettings, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 9)
            encoder.dispatchThreads(.init(width: polygonPairCount, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
                                             height: 1, depth: 1))
        }
        if previousPolygonSensorPairCount > 0 {
            encoder.memoryBarrier(scope: .buffers)
            let pipeline = pipelines["nativeCompactMissingSensorEvents"]!
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in [previousPolygonSensorPairBuffer, currentPolygonSensorPairs,
                state.eventCount, state.eventRecords].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            var settings = SIMD4(UInt32(previousPolygonSensorPairCount), UInt32(polygonPairCount),
                                 UInt32(requestedEventCapacity), UInt32(1))
            encoder.setBytes(&settings, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
            encoder.dispatchThreads(.init(width: previousPolygonSensorPairCount, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup),
                                             height: 1, depth: 1))
        }
        if !snapshot.hitTests.isEmpty {
            // Na buforach roboczych tego kroku, po ostatnim kernelu, który zmienia kontury i pozy brył.
            dispatch("nativeHitTest", buffers: [hitTestPoints, state.workingContourPoints, state.workingContourCounts,
                state.workingBubbles, rigidState.count > 0 ? rigidState.bodies : state.eventRecords,
                rigidState.count > 0 ? rigidState.vertices : state.eventRecords,
                rigidState.count > 0 ? rigidState.triangles : state.eventRecords, state.control,
                hitTestCounts, hitTestResultBuffer], threads: snapshot.hitTests.count)
        }
        encoder.endEncoding()
        if let beforeCommit {
            let working = NativeMetalRenderHandoff(
                points: state.workingContourPoints, counts: state.workingContourCounts,
                bubbles: state.workingBubbles,
                bubbleIDs: snapshot.sourceBubbles.map { ObjectID(rawValue: UInt64(bitPattern: Int64($0.id.rawValue))) },
                contourStride: state.contourStride,
                // Strona t−1 kroku w toku to strona opublikowana: nietknięta, dopóki krok nie zostanie opublikowany.
                previousPoints: lastSnapshot == nil ? nil : state.publishedContourPoints,
                previousCounts: lastSnapshot == nil ? nil : state.publishedContourCounts,
                previousBubbles: lastSnapshot == nil ? nil : state.publishedBubbles,
                previousBubbleIDs: previousPublicationBubbleIDs,
                // Rekordy brył kroku w toku niosą jego obie pozy: przed krokiem (t) i po nim (t+1).
                bodies: rigidState.count > 0 ? rigidState.bodies : nil, bodyIDs: rigidState.workingIDs)
            try beforeCommit(working)
        }
        // Od tej chwili krok pisze stronę roboczą, która w opublikowanym uchwycie jest stroną t−1.
        publishedRenderHandoff?.invalidatePreviousContours()
        let encodingEnd = DispatchTime.now().uptimeNanoseconds
        // Jedyny await/commit: wszystkie etapy zostały już zakodowane.
        let timing = try await commandExecutor.complete(command)
        let waitingEnd = DispatchTime.now().uptimeNanoseconds
        let contactResult = state.contactControl.contents().load(as: NativeMetalContactControl.self)
        let solverResult = state.solverControl.contents().load(as: NativeMetalSolverControl.self)
        let safetyResult = state.safetyControl.contents().load(as: NativeMetalSafetyControl.self)
        var profile = NativeMetalFrameProfile()
        profile.commandBufferCount = 1
        profile.encoderCount = 2
        profile.bubbleUploadCount = snapshot.bubbleChanges.count
        profile.segmentUploadCount = snapshot.segmentChanges.count
        profile.bubbleUploadCommandCount = NativeMetalCopyRun.coalesce(snapshot.bubbleChanges.map { ($0.index, $0.index) }).count
        profile.rigidBodyUploadCount = rigidState.bodyUploadCount
        profile.rigidGeometryUploadCount = rigidState.geometryUploadCount
        profile.hostEncodingMilliseconds = milliseconds(encodingEnd - encodingStart)
        profile.hostWaitingMilliseconds = milliseconds(waitingEnd - encodingEnd)
        profile.encodingStartNanoseconds = encodingStart
        profile.waitingEndNanoseconds = waitingEnd
        profile.stageGPUMilliseconds = ["frame": timing.gpuMilliseconds]
        let diagnostics = NativeMetalFrameTelemetry(backend: .nativeMetal, commandBufferCount: 1, encoderCount: 2,
            cacheHitCount: Int(contactResult.cache.x), cacheResetCount: Int(contactResult.cache.y),
            contactCount: Int(contactResult.counts.y), didEncounterNonFinite: safetyResult.counts.w & 1 != 0,
            gpuMilliseconds: timing.gpuMilliseconds, solverIterationCount: configuration.solverIterationCount,
            ccdCandidateCount: Int(safetyResult.counts.x), guardCorrectionCount: Int(safetyResult.counts.y),
            cacheInvalidationCount: Int(safetyResult.counts.z))
        func rejectSafety(_ reason: NativeMetalWorldError) -> NativeMetalSafetyFailure {
            .init(reason: reason, telemetry: diagnostics, profile: profile)
        }
        guard safetyResult.counts.w & 1 == 0 else { throw rejectSafety(.nonFinite) }
        guard safetyResult.counts.w & 2 == 0 else { throw rejectSafety(.guardFailure) }
        guard safetyResult.counts.w & 4 == 0 else { throw rejectSafety(.invalidFrame) }
        if let postSolver = state.diagnosticPostSolverPositions,
           let postGuard = state.diagnosticPostGuardPositions {
            let solverValues = postSolver.contents().bindMemory(to: SIMD2<Float>.self, capacity: state.bubbleCapacity)
            let guardValues = postGuard.contents().bindMemory(to: SIMD2<Float>.self, capacity: state.bubbleCapacity)
            let solverPositions = (0..<count).map { SIMD2<Float>(solverValues[$0].x, solverValues[$0].y) }
            let guardPositions = (0..<count).map { SIMD2<Float>(guardValues[$0].x, guardValues[$0].y) }
            guard solverPositions.allSatisfy(\.isFiniteVector), guardPositions.allSatisfy(\.isFiniteVector) else {
                throw rejectSafety(.nonFinite)
            }
            stageDiagnostics = .init(postSolverPositions: solverPositions, postGuardPositions: guardPositions)
        }
        let cacheRecords = state.workingCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)
        let completedCache = Array(UnsafeBufferPointer(start: cacheRecords, count: Int(contactResult.counts.z)))
        guard completedCache.allSatisfy({ $0.geometry.x.isFinite && $0.geometry.y.isFinite
            && $0.geometry.z.isFinite && $0.geometry.w.isFinite && $0.lambda.isFinite
            && $0.response.y.isFinite }), solverResult.physics.z.isFinite
        else { throw rejectSafety(.nonFinite) }
        // Skończony ujemny mnożnik to wartość poza zakresem, nie NaN ani ∞: odrzuca tylko krok.
        guard completedCache.allSatisfy({ $0.lambda >= 0 }) else { throw rejectSafety(.invalidFrame) }
        let contacts = completedCache.filter { $0.lastSeenFrame == nextFrame }.map { record in
            // ID API referencyjnego jest skrótem; cache GPU zawsze używa pełnego klucza.
            var hash: UInt64 = 14695981039346656037
            hash = (hash ^ UInt64(record.key.kind)) &* 1099511628211
            hash = (hash ^ UInt64(bitPattern: record.key.first)) &* 1099511628211
            hash = (hash ^ UInt64(bitPattern: record.key.second)) &* 1099511628211
            return NativeSolverContact(id: hash, kind: record.key.kind == 0 ? .bubbleBubble : .bubbleSegment,
                bubbleA: .init(rawValue: Int(record.key.first)),
                bubbleB: record.key.kind == 0 ? .init(rawValue: Int(record.key.second)) : nil,
                segment: record.key.kind == 1 ? Int(record.key.second) : nil,
                normal: SIMD2(record.geometry.x, record.geometry.y), pointQ: SIMD2(record.geometry.z, record.geometry.w),
                penetration: record.response.y, allowedSide: record.response.z == 0 ? nil : record.response.z,
                accumulatedCompression: record.lambda, age: Int(record.age))
        }
        var bubbles = snapshot.sourceBubbles
        let records = state.workingBubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: state.bubbleCapacity)
        for index in bubbles.indices {
            guard records[index].identity.x == Int64(bubbles[index].id.rawValue) else { throw NativeMetalSolverError.invalidSnapshot }
            records[index].unpack(into: &bubbles[index])
        }
        guard !bubbles.contains(where: { !$0.isFiniteState }) else { throw rejectSafety(.nonFinite) }
        let readsContours = snapshot.publicSettings == nil
        let pointRecords = readsContours ? state.workingContourPoints.contents().bindMemory(
            to: SIMD2<Float>.self, capacity: count * state.contourStride) : nil
        let pointCounts = state.workingContourCounts.contents().bindMemory(to: UInt32.self, capacity: state.bubbleCapacity)
        let packets = state.renderPackets.contents().bindMemory(to: NativeMetalRenderPacket.self, capacity: state.bubbleCapacity)
        var contours: [NativeSolverBubbleID: [SIMD2<Float>]] = [:]
        var renderData: [SIMD4<Float>] = []
        var effectiveRadii: [NativeSolverBubbleID: Float] = [:]
        var bubbleBounds: [NativeSolverBubbleID: SIMD4<Float>] = [:]
        var deformationCount = 0
        var maximumRelativeDeformation: Float = 0
        for index in bubbles.indices {
            guard pointCounts[index] >= 32, pointCounts[index] <= state.contourStride,
                  packets[index].identity.x == Int64(bubbles[index].id.rawValue),
                  packets[index].geometry == SIMD4(bubbles[index].center.x, bubbles[index].center.y,
                                                  bubbles[index].targetRadius, bubbles[index].rotation)
            else { throw NativeMetalSolverError.invalidSnapshot }
            let points = (0..<(readsContours ? Int(pointCounts[index]) : 0)).map { point -> SIMD2<Float> in
                pointRecords![index * state.contourStride + point]
            }
            guard points.allSatisfy(\.isFiniteVector) else { throw rejectSafety(.nonFinite) }
            guard points.indices.allSatisfy({ point in
                (points[(point + 1) % points.count] - points[point]).euclideanLength <= contourConfiguration.maxContourSegmentLength
            }) else { throw rejectSafety(.invalidFrame) }
            let deformation = packets[index].deformation.x
            // NaN i ±∞ kończą świat (`.nonFinite`); skończona wartość poza zakresem odrzuca tylko krok (`.invalidFrame`).
            guard deformation.isFinite else { throw rejectSafety(.nonFinite) }
            guard deformation >= 0, deformation <= 1 else { throw rejectSafety(.invalidFrame) }
            let effectiveRadius = packets[index].deformation.y
            guard effectiveRadius.isFinite else { throw rejectSafety(.nonFinite) }
            guard effectiveRadius >= 0, effectiveRadius <= bubbles[index].targetRadius else {
                throw rejectSafety(.invalidFrame)
            }
            if deformation * bubbles[index].targetRadius > contourConfiguration.positionTolerance { deformationCount += 1 }
            maximumRelativeDeformation = max(maximumRelativeDeformation, deformation)
            if readsContours { contours[bubbles[index].id] = points }
            effectiveRadii[bubbles[index].id] = effectiveRadius
            let bounds = records[index].bounds
            guard (0..<4).allSatisfy({ bounds[$0].isFinite }) else { throw rejectSafety(.nonFinite) }
            guard bounds.x <= bounds.z, bounds.y <= bounds.w else { throw rejectSafety(.invalidFrame) }
            bubbleBounds[bubbles[index].id] = bounds
            renderData.append(packets[index].geometry)
        }
        if collectDispatchStatistics {
            let counts = state.dispatchStatistics.contents().load(as: SIMD4<UInt32>.self)
            let safetyCounts = state.dispatchStatistics.contents().advanced(by: 16).load(as: SIMD4<UInt32>.self)
            let pipelineCounts = state.dispatchStatistics.contents().advanced(by: 32).load(as: SIMD4<UInt32>.self)
            let dispatchArguments = state.indirectArguments.contents().bindMemory(to: SIMD4<UInt32>.self,
                capacity: 5 + state.scanBlockSums.count * 2)
            profile.stageGPUWorkItemCounts = ["cacheMatch": Int(counts.x), "cacheRetain": Int(counts.y),
                "cacheCompaction": Int(counts.z), "candidateCompaction": Int(counts.w),
                "ccdAnalyticTests": Int(safetyCounts.y), "guardAnalyticTests": Int(safetyCounts.z),
                "ccdFinitePathTests": Int(safetyCounts.w), "adjacencyRecords": Int(pipelineCounts.x),
                "residualRecords": Int(pipelineCounts.y), "cacheDispatchThreads": Int(dispatchArguments[3].x) * 32,
                "candidateDispatchThreads": Int(dispatchArguments[0].x) * 32]
        }
        let converged = solverResult.physics.z <= solverResult.physics.y
        let report = NativeSolverReport(iterations: Int(solverResult.counts.y),
            maximumPenetration: contacts.map(\.penetration).max() ?? 0, converged: converged,
            didReachIterationLimit: !converged && solverResult.counts.y == solverResult.counts.w,
            positionCorrectionCount: Int(solverResult.counts.z), deformationCount: deformationCount,
            initialResidualNorm: solverResult.physics.w, finalResidualNorm: solverResult.physics.z,
            maximumRelativeDeformation: maximumRelativeDeformation,
            candidatePairCount: Int(contactResult.counts.x), generatedContactCount: contacts.count,
            persistentContactCount: Int(contactResult.cache.x), toiTestCount: Int(safetyResult.counts.x),
            sideCorrectionCount: Int(safetyResult.counts.y),
            totalMilliseconds: milliseconds(waitingEnd - encodingStart), hasNonFiniteState: false)
        var frame = NativeSolverFrame(bubbles: bubbles, contacts: contacts, report: report,
            telemetry: .init(backend: .nativeMetal, commandBufferCount: 1, encoderCount: 2,
                cacheHitCount: Int(contactResult.cache.x), cacheResetCount: Int(contactResult.cache.y),
                contactCount: contacts.count, gpuMilliseconds: timing.gpuMilliseconds,
                solverIterationCount: configuration.solverIterationCount,
                ccdCandidateCount: Int(safetyResult.counts.x), guardCorrectionCount: Int(safetyResult.counts.y),
                cacheInvalidationCount: Int(safetyResult.counts.z)),
            profile: profile, contours: contours, renderData: renderData,
            effectiveRadii: effectiveRadii, bubbleBounds: bubbleBounds, isComplete: true)
        if !snapshot.hitTests.isEmpty {
            let records = hitTestResultBuffer.contents().bindMemory(to: NativeHitTestResult.self, capacity: snapshot.hitTests.count)
            frame.hitTestResults = (0..<snapshot.hitTests.count).map { index in
                records[index].found == 0 ? nil : ObjectID(rawValue: records[index].identity)
            }
        }
        let overflowCounters = state.candidateOverflow.contents().load(as: SIMD4<UInt32>.self)
        frame.contactCandidateOverflowCount = Int(overflowCounters.x)
        frame.maximumContactCandidatesPerObject = Int(overflowCounters.y)
        if snapshot.publicSettings != nil {
            let total = Int(state.eventCount.contents().load(as: UInt32.self))
            let publishedCount = min(total, requestedEventCapacity)
            let records = state.eventRecords.contents().bindMemory(to: NativeMetalEventRecord.self,
                capacity: state.eventCapacity)
            frame.events = (0..<publishedCount).map { index in
                let record = records[index]
                let first = ObjectID(rawValue: record.participants.x), second = ObjectID(rawValue: record.participants.y)
                switch record.metadata.x {
                case 1: return .enteredSensor(sensor: first, object: second)
                case 2: return .exitedSensor(sensor: first, object: second)
                default: return .mergeContact(first, second, point: [record.point.x, record.point.y])
                }
            }
            frame.eventOverflow = WorldEventOverflow(droppedCount: total - publishedCount)
        }
        frame.regionRemovals = Set(bubbles.indices.compactMap { records[$0].publicFlags.w == 1 ? bubbles[$0].id : nil })
        frame.regionWraps = Set(bubbles.indices.compactMap { records[$0].publicFlags.w == 2 ? bubbles[$0].id : nil })
        let rigidResult = try rigidState.completed()
        let rigidContacts = hasRigidBodies ? rigidState.contactRecords() : []
        let driveContacts = NativeRigidPolygonState.driveContacts(of: rigidContacts)
        // Synchroniczna publikacja dopiero po pomyślnym wykonaniu i readbacku.
        rigidState.publish(rigidResult.objects)
        publishedPolygons = rigidResult.objects
        publishedDriveContacts = driveContacts
        publishedRigidContacts = rigidContacts
        removedPolygons = rigidResult.removed
        wrappedPolygons = rigidResult.wrapped
        let previousIDs = previousPublicationBubbleIDs
        let hadPreviousPublication = lastSnapshot != nil
        state.publish()
        previousSensorPairs = pairCount > 0 ? currentSensorPairs : nil
        previousSensorPairCount = pairCount
        previousPolygonSensorPairs = polygonPairCount > 0 ? currentPolygonSensorPairs : nil
        previousPolygonSensorPairCount = polygonPairCount
        state.publishedCacheCount = completedCache.count
        cachedContacts = completedCache
        publishedCandidateCount = Int(contactResult.counts.x)
        frameNumber = nextFrame
        persistentState = state
        lastSnapshot = snapshot
        publishedSolverFrame = frame
        if snapshot.publicSettings != nil {
            publishedRenderHandoff = NativeMetalRenderHandoff(
                points: state.publishedContourPoints, counts: state.publishedContourCounts,
                bubbles: state.publishedBubbles,
                bubbleIDs: snapshot.sourceBubbles.map { ObjectID(rawValue: UInt64(bitPattern: Int64($0.id.rawValue))) },
                contourStride: state.contourStride,
                // Po publikacji strona robocza trzyma kontury poprzedniej publikacji (t−1).
                previousPoints: hadPreviousPublication ? state.workingContourPoints : nil,
                previousCounts: hadPreviousPublication ? state.workingContourCounts : nil,
                previousBubbles: hadPreviousPublication ? state.workingBubbles : nil,
                previousBubbleIDs: previousIDs,
                // Opublikowane rekordy brył niosą pozę t i t−1 (stan sprzed ostatniego kroku).
                bodies: rigidState.publishedBodies, bodyIDs: rigidState.publishedIDs)
        }
        if readsContours { publishedContourCPUReadbackCount += 1 }
        return frame
    }

    /// Kolejność baniek ostatniej publikacji, czyli strony t−1 po publikacji następnego kroku.
    private var previousPublicationBubbleIDs: [ObjectID] {
        (lastSnapshot?.sourceBubbles ?? []).map { ObjectID(rawValue: UInt64(bitPattern: Int64($0.id.rawValue))) }
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }
}

/// Ciągły zakres kopiowany jednym poleceniem blit.
struct NativeMetalCopyRun: Equatable {
    let source: Int
    let destination: Int
    let count: Int

    /// Scala pary (źródło, cel) w zakresy, w których oba indeksy rosną o jeden.
    /// Kolejność wejścia jest zachowana, więc semantyka jest taka sama jak przy kopiowaniu rekord po rekordzie.
    static func coalesce(_ pairs: [(Int, Int)]) -> [NativeMetalCopyRun] {
        var runs: [NativeMetalCopyRun] = []
        runs.reserveCapacity(pairs.count)
        for (source, destination) in pairs {
            if let last = runs.last, last.source + last.count == source, last.destination + last.count == destination {
                runs[runs.count - 1] = NativeMetalCopyRun(source: last.source, destination: last.destination, count: last.count + 1)
            } else {
                runs.append(NativeMetalCopyRun(source: source, destination: destination, count: 1))
            }
        }
        return runs
    }
}

/// Rosnący bufor współdzielony, używany ponownie między klatkami zamiast alokacji w każdej klatce.
@MainActor
final class NativeMetalReusableBuffer {
    private(set) var buffer: MTLBuffer?

    func upload<T>(_ values: [T], device: MTLDevice) throws -> MTLBuffer {
        let target = try reserve(count: values.count, stride: MemoryLayout<T>.stride, device: device)
        values.withUnsafeBytes { bytes in
            if let base = bytes.baseAddress { memcpy(target.contents(), base, bytes.count) }
        }
        return target
    }

    func reserve(count: Int, stride: Int, device: MTLDevice) throws -> MTLBuffer {
        let (length, overflow) = max(1, count).multipliedReportingOverflow(by: stride)
        guard !overflow, length <= device.maxBufferLength else { throw NativeMetalSolverError.allocationFailed }
        if let buffer, buffer.length >= length { return buffer }
        // Wzrost geometryczny: realokacja jest rzadka, gdy rośnie liczba sensorów lub baniek.
        let grown = min(device.maxBufferLength, max(length, (buffer?.length ?? 0) * 2))
        guard let created = device.makeBuffer(length: grown, options: .storageModeShared) else {
            throw NativeMetalSolverError.allocationFailed
        }
        buffer = created
        return created
    }
}

/// Dwa naprzemienne bufory: jeden trzyma opublikowane pary, drugi przyjmuje następną klatkę.
@MainActor
final class NativeMetalAlternatingBuffer {
    private let slots = [NativeMetalReusableBuffer(), NativeMetalReusableBuffer()]

    func next<T>(avoiding previous: MTLBuffer?, zeroedCount count: Int, of type: T.Type,
                 device: MTLDevice) throws -> MTLBuffer {
        let slot = slots[0].buffer != nil && slots[0].buffer === previous ? slots[1] : slots[0]
        let buffer = try slot.reserve(count: count, stride: MemoryLayout<T>.stride, device: device)
        memset(buffer.contents(), 0, count * MemoryLayout<T>.stride)
        return buffer
    }
}

@MainActor
final class NativeMetalSensorScratch {
    let records = NativeMetalReusableBuffer()
    let vertices = NativeMetalReusableBuffer()
    let allowed = NativeMetalReusableBuffer()
    let polygonAllowed = NativeMetalReusableBuffer()
    let pairs = NativeMetalAlternatingBuffer()
    let polygonPairs = NativeMetalAlternatingBuffer()
}

/// Kompiluje shadery solvera raz na urządzenie. Stany pipeline'ów są niezmienne i współdzielone,
/// więc każda instancja solvera na tym samym urządzeniu używa ich ponownie zamiast kompilować przy starcie.
@MainActor
enum NativeMetalPipelineCache {
    struct Compiled {
        let predict: MTLComputePipelineState
        let stages: [String: MTLComputePipelineState]
    }

    private static var compiled: [UInt64: Compiled] = [:]

    static let stageNames: [String] = ["nativePrepareGrid", "nativeBuildGrid", "nativeSortGrid", "nativeEmitCandidates",
        "nativePrepareCandidateCounts", "nativeCompactCandidates", "nativeBuildContacts",
        "nativePrepareContactFlags", "nativeCompactActiveContacts", "nativeMatchContactCache",
        "nativeRetainContactCache", "nativeCompactContactCache", "nativeScanBlocks", "nativePrepareIndirectArguments",
        "nativeAddScanBlockOffsets", "nativeFinishScan", "nativeClearAdjacency", "nativeEmitAdjacency", "nativeBuildAdjacency",
        "nativePrepareSolverContacts", "nativeApplyWarmStart", "nativeUpdateContactMultipliers",
        "nativeSolveJacobi", "nativeMeasureResidual", "nativeReduceSolverResidual",
        "nativeCapturePositions",
        "nativeUpdateVelocities", "nativeDampContactNormalMotion", "nativeFinalizeSolverContacts", "nativeFindFastCandidates",
        "nativeResolveCCD", "nativeApplyCenterGuards", "nativeSeparateContainedBubbles",
        "nativeReapplyCenterGuards", "nativeValidateBubbleContainment", "nativeInvalidateSafetyCache", "nativeCheckFinite",
        "nativeAccumulateContactPressure", "nativeSeedStructuralContours", "nativeGenerateContours", "nativePrepareRenderData",
        "nativeApplyPublicRegion", "nativeInvalidateRegionCache",
        "nativeCompactMergeEvents",
        "nativeCompactSensorEvents",
        "nativeCompactPolygonSensorEvents",
        "nativeCompactMissingSensorEvents",
        "nativeRigidPredict", "nativeRigidEmitCandidates", "nativeRigidContacts", "nativeRigidApplyBubbles", "nativeRigidApplyBodies", "nativeRigidGuardWalls", "nativeRigidFinish",
        "nativeRigidResolveCCD", "nativeRigidApplyCCD", "nativeSolveJoints", "nativeApplyJointBodies", "nativeApplyJointBubbles",
        "nativeHitTest"]

    static func pipelines(for device: MTLDevice) throws -> Compiled {
        if let cached = compiled[device.registryID] { return cached }
        let source = try NativeMetalShaderSource.solverSource()
        let options = MTLCompileOptions()
        // Finite jest kontraktem bezpieczeństwa: fast-math zakłada jego spełnienie.
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: source, options: options)
        guard let function = library.makeFunction(name: "nativePredict")
        else { throw NativeMetalSolverError.resourceUnavailable }
        let predict = try device.makeComputePipelineState(function: function)
        var stages: [String: MTLComputePipelineState] = [:]
        for name in stageNames {
            guard let function = library.makeFunction(name: name) else { throw NativeMetalSolverError.resourceUnavailable }
            stages[name] = try device.makeComputePipelineState(function: function)
        }
        let result = Compiled(predict: predict, stages: stages)
        compiled[device.registryID] = result
        return result
    }
}

/// Wczytuje dołączone pliki `.metal-source` kompilowane w czasie działania.
enum NativeMetalShaderSource {
    static let solverFiles = ["NativeGeometryKernels", "NativeXPBDKernels", "NativePostSolveKernels"]

    static func load(_ name: String) throws -> String {
        guard let url = Bundle.module.url(forResource: name, withExtension: "metal-source") else {
            throw NativeMetalSolverError.resourceUnavailable
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func solverSource() throws -> String {
        try solverFiles.map(load).joined(separator: "\n")
    }
}
