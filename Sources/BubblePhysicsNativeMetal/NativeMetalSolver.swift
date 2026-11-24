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
    let scanValues: MTLBuffer
    let scanOffsets: MTLBuffer
    /// Tylko dla dawnego skanu blokowego (wzorzec testowy); `scanBlockSums.count` wyznacza też rozmiar `indirectArguments`.
    let scanBlockSums: [MTLBuffer]
    let scanBlockOffsets: [MTLBuffer]
    let scanCapacity: Int
    let dispatchStatistics: MTLBuffer
    let indirectArguments: MTLBuffer
    /// Indeks pierwszego slotu `NativeMetalSubstep.EndArgument` w `indirectArguments` (za slotami pętli i skanu).
    let endArgumentBase: Int
    var contactCache: MTLBuffer { publishedIsPing ? cachePing : cachePong }
    var workingCache: MTLBuffer { publishedIsPing ? cachePong : cachePing }
    var publishedCacheCount = 0
    let adjacency: MTLBuffer
    /// uint4 na krok: x = pary odrzucone przez limit k lub pojemność, y = największe zapotrzebowanie na obiekt.
    let candidateOverflow: MTLBuffer
    /// Licznik wyrzucany: sąsiedztwo końca kroku (z rekordów kontaktów) liczy do niego, więc ten sam odrzucony kandydat nie wchodzi drugi raz
    /// do `candidateOverflow` (CD-D-26).
    let endAdjacencyOverflow: MTLBuffer
    let adjacencyCounts: MTLBuffer
    let contactEndpoints: MTLBuffer
    let safetyControl: MTLBuffer
    let segmentsPing: MTLBuffer
    let segmentsPong: MTLBuffer
    let bubbleUpdates: MTLBuffer
    let segmentUpdates: MTLBuffer
    let control: MTLBuffer
    /// Bufory pętli podkroków silnika 4.0.0 (`NativeForceKernels`): float2 na bańkę, poza `broadphaseMargin` (float na bańkę).
    /// `acceleration` to bieżące a (kontakty i siły bez kontaktów), `nonContactAcceleration` to a₀ z początku kroku,
    /// `contactForces` to wynik `nativeContactForces`, `referencePositions` to x₀ z ostatniej budowy siatki.
    let acceleration: MTLBuffer
    let nonContactAcceleration: MTLBuffer
    let contactForces: MTLBuffer
    let referencePositions: MTLBuffer
    let broadphaseMargin: MTLBuffer
    /// Jeden `NativeMetalSubstepControl`; czasy, liczniki i obiekt wyznaczający h.
    let substepControl: MTLBuffer
    /// Argumenty pośredniej dyspozycji jąder podkroku (trzy uint: liczba grup, 1, 1); zero grup dla podkroku pustego.
    let substepDispatch: MTLBuffer
    /// h każdego podkroku klatki (`NativeMetalSubstep.frameLimit` wpisów).
    let substepSteps: MTLBuffer
    /// Jeden `NativeMetalContactAssertion`: pierwsze naruszenie asercji kontaktu w klatce, zerowany przed kodowaniem.
    let contactAssertion: MTLBuffer
    /// Argumenty pośrednich dyspozycji jąder końca kroku (uint4 na bramkę: liczba grup, 1, 1, 0); zero grup, dopóki krok trwa.
    let endGates: MTLBuffer
    /// Przy `captureSubsteps`: float4 (x.xy, v.xy) na bańkę na podkrok, indeks podkroku · liczba baniek kroku + indeks bańki. Bez przełącznika nil.
    let substepCapture: MTLBuffer?
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
         contourStride: Int = 64, eventCapacity: Int = 1,
         captureSubsteps: Bool = false) throws {
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
        let (mergedCapacity, mergedOverflow) = contactCapacity.multipliedReportingOverflow(by: 2)
        guard !mergedOverflow, mergedCapacity <= Int(UInt32.max) else { throw NativeMetalSolverError.allocationFailed }
        scanCapacity = max(mergedCapacity, bubbleCapacity * 2)
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
        endArgumentBase = 5 + sums.count * 2
        indirectArguments = try buffer("indirectArguments", endArgumentBase + NativeMetalSubstep.EndArgument.allCases.count,
                                       MemoryLayout<SIMD4<UInt32>>.stride)
        dispatchStatistics = try buffer("dispatchStatistics", 3, MemoryLayout<SIMD4<UInt32>>.stride)
        adjacency = try buffer("solver.adjacency", rowCapacity, MemoryLayout<SIMD4<UInt32>>.stride)
        candidateOverflow = try buffer("candidateOverflow", 1, MemoryLayout<SIMD4<UInt32>>.stride)
        endAdjacencyOverflow = try buffer("endAdjacencyOverflow", 1, MemoryLayout<SIMD4<UInt32>>.stride)
        adjacencyCounts = try buffer("solver.adjacencyCounts", bubbleCapacity, MemoryLayout<UInt32>.stride)
        contactEndpoints = try buffer("solver.endpoints", contactCapacity, MemoryLayout<SIMD4<UInt32>>.stride)
        safetyControl = try buffer("safety.control", 1, MemoryLayout<NativeMetalSafetyControl>.stride)
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
        acceleration = try buffer("substep.acceleration", bubbleCapacity, MemoryLayout<SIMD2<Float>>.stride)
        nonContactAcceleration = try buffer("substep.nonContactAcceleration", bubbleCapacity, MemoryLayout<SIMD2<Float>>.stride)
        contactForces = try buffer("substep.contactForces", bubbleCapacity, MemoryLayout<SIMD2<Float>>.stride)
        referencePositions = try buffer("substep.referencePositions", bubbleCapacity, MemoryLayout<SIMD2<Float>>.stride)
        broadphaseMargin = try buffer("substep.broadphaseMargin", bubbleCapacity, MemoryLayout<Float>.stride)
        substepControl = try buffer("substep.control", 1, MemoryLayout<NativeMetalSubstepControl>.stride)
        substepDispatch = try buffer("substep.dispatch", 1, 3 * MemoryLayout<UInt32>.stride)
        substepSteps = try buffer("substep.steps", NativeMetalSubstep.frameLimit, MemoryLayout<Float>.stride)
        contactAssertion = try buffer("substep.contactAssertion", 1, MemoryLayout<NativeMetalContactAssertion>.stride)
        endGates = try buffer("substep.endGates", NativeMetalSubstep.EndGate.allCases.count, MemoryLayout<SIMD4<UInt32>>.stride)
        let (captureCount, captureOverflow) = bubbleCapacity.multipliedReportingOverflow(by: NativeMetalSubstep.frameLimit)
        guard !captureOverflow else { throw NativeMetalSolverError.allocationFailed }
        substepCapture = captureSubsteps ? try buffer("substep.capture", captureCount, MemoryLayout<SIMD4<Float>>.stride) : nil
        eventCount = try buffer("eventCount", 1, MemoryLayout<UInt32>.stride)
        eventRecords = try buffer("eventRecords", eventCapacity, MemoryLayout<NativeMetalEventRecord>.stride)
    }

    func publish() { publishedIsPing.toggle() }

    /// Podkroki ostatniego kroku z bufora `substepSteps` i `substepCapture`: h, x i v każdej z `bubbleIDs` (surowe ID w kolejności
    /// indeksów bańki) po każdym podkroku. Pusta bez `captureSubsteps`. Liczbę podkroków daje `substepControl.counts.y`.
    func capturedSubsteps(bubbleIDs: [UInt64]) -> [NativeMetalSubstepSample] {
        guard let capture = substepCapture else { return [] }
        let control = substepControl.contents().bindMemory(to: NativeMetalSubstepControl.self, capacity: 1).pointee
        let substeps = min(Int(control.counts.y), NativeMetalSubstep.frameLimit)
        let steps = substepSteps.contents().bindMemory(to: Float.self, capacity: NativeMetalSubstep.frameLimit)
        let states = capture.contents().bindMemory(to: SIMD4<Float>.self, capacity: bubbleCapacity * NativeMetalSubstep.frameLimit)
        return (0..<substeps).map { substep in
            var bubbles: [UInt64: NativeMetalSubstepSample.Body] = [:]
            for (index, id) in bubbleIDs.enumerated() {
                let state = states[substep * bubbleIDs.count + index]
                bubbles[id] = .init(position: SIMD2(state.x, state.y), velocity: SIMD2(state.z, state.w))
            }
            return NativeMetalSubstepSample(h: steps[substep], bubbles: bubbles)
        }
    }
}

/// Trwały stan GPU i pętla podkroków silnika 4.0.0; publikacja świata czeka na asercje kontaktu.
@MainActor
package final class NativeMetalSolver: NativeMetalFrameExecuting {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipelines: [String: MTLComputePipelineState]
    package let configuration: NativeMetalConfiguration
    /// Podkroki ostatniego kroku w kolejności, gdy `configuration.captureSubsteps`; w przeciwnym razie pusta (szew testów 4.0.0).
    package private(set) var capturedSubsteps: [NativeMetalSubstepSample] = []
    private let candidateCapacity: Int?
    private let collectDispatchStatistics: Bool
    private let commandExecutor: any NativeMetalCommandExecuting
    private var inFlight = false
    /// Podkroki poprzedniej klatki: pierwsza para buforów następnej ma 2 × tyle (najmniej 2), CD-D-18.
    private var previousFrameSubstepCount = 0
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
    private let forceBuffers = NativeMetalForceBuffers()
    private(set) var publishedPolygons: [ObjectID: NativePublicObject] = [:]
    private(set) var publishedDriveContacts: [ObjectID: [DriveBlockingContact]] = [:]
    /// Kontakty brył ostatniego kroku z sumą normalnych Δλ (zdarzenia kontaktu w `NativePublicWorld`).
    private(set) var publishedRigidContacts: [NativeRigidPolygonState.ContactRecord] = []
    private(set) var removedPolygons: Set<ObjectID> = []
    private(set) var wrappedPolygons: Set<ObjectID> = []
    private(set) var cachedContacts: [NativeContactCacheRecord] = []
    private var publishedCandidateCount = 0
    /// Klucze kandydatów ostatniej publikacji, czytane z bufora dopiero na żądanie (szew testów; klatka ich nie kopiuje).
    /// Bufor kandydatów jest współdzielony z następnym krokiem, więc `executeSnapshot` zeruje licznik przy kodowaniu:
    /// po odrzuconym kroku lub z klatką w locie wartość to `[]`, nigdy klucze innego kroku niż ostatnia publikacja.
    var candidateKeys: [NativeContactKey] {
        guard publishedCandidateCount > 0, let buffer = persistentState?.candidates else { return [] }
        let records = buffer.contents().bindMemory(to: NativeMetalCandidate.self, capacity: publishedCandidateCount)
        return (0..<publishedCandidateCount).map { records[$0].key }
    }
    private(set) var persistentState: NativeMetalPersistentState?
    package private(set) var publishedSolverFrame: NativeSolverFrame?
    private(set) var publishedRenderHandoff: NativeMetalRenderHandoff?
    private(set) var publishedContourCPUReadbackCount = 0

    /// Limit k kandydatów kontaktu na obiekt, wspólny dla baniek, odcinków i brył (zadanie 14: k = 48; zadanie 32: k = 128, bo wiersz statycznej ściany scena mieszana wypełnia wszystkimi bryłami w zasięgu).
    nonisolated package static let candidateLimitPerObject = 128

    /// Szerokość grupy jądra jednej grupy: min(`maxTotalThreadsPerThreadgroup` potoku, 1024); A11 może dać mniej niż Mac (CD-D-27).
    static func singleGroupWidth(_ pipeline: MTLComputePipelineState) -> Int { min(pipeline.maxTotalThreadsPerThreadgroup, 1024) }

    /// Szczegóły naruszenia asercji kontaktu z rekordu GPU: obiekty (bańka i drugi koniec), odległość i dla zmiany strony krawędzi numer krawędzi
    /// w wielokącie właściciela (kolejność identyfikatorów jego odcinków; krawędzie współliniowe są scalone).
    static func violationDetail(_ record: NativeMetalContactAssertion, kind: NativeMetalContactAssertion.Kind,
                                segments: [NativeSolverSegment]) -> NativeMetalFailureDetail {
        var edge: Int?
        if kind == .edgeSide {
            let owner = Int(truncatingIfNeeded: record.objects.y)
            edge = segments.filter { $0.ownerID == owner }.map(\.id).sorted().firstIndex(of: Int(record.state.y))
        }
        return NativeMetalFailureDetail(objectIDs: [record.objects.x, record.objects.y], edgeIndex: edge,
                                        distance: kind == .insideBody ? nil : record.detail.x)
    }

    /// Iteracje solvera brył raz na krok (silnik 4.0.0: stała, dawna wartość domyślna `solverIterationCount`).
    static let rigidSolverIterationCount = 8

    /// Suma długości buforów związanych z kontaktami; 0 przed pierwszym krokiem.
    var contactMemoryBytes: Int {
        guard let s = persistentState else { return 0 }
        let buffers: [MTLBuffer] = [s.cachePing, s.cachePong, s.contacts, s.candidates, s.candidateRows,
            s.scanValues, s.scanOffsets, s.adjacency, s.contactEndpoints]
        return buffers.reduce(0) { $0 + $1.length }
    }
    var rigidContactMemoryBytes: Int { rigidState.contactMemoryBytes }

    package init(device: MTLDevice, commandExecutor: (any NativeMetalCommandExecuting)? = nil,
         configuration: NativeMetalConfiguration = .default, candidateCapacity: Int? = nil,
         collectDispatchStatistics: Bool = false) throws {
        self.device = device
        self.rigidState = NativeRigidPolygonState(device: device)
        self.jointState = NativeJointState(device: device)
        self.configuration = configuration.sanitized
        self.candidateCapacity = candidateCapacity
        self.collectDispatchStatistics = collectDispatchStatistics
        self.commandExecutor = commandExecutor ?? NativeMetalCommandExecutor()
        guard let queue = device.makeCommandQueue() else { throw NativeMetalSolverError.resourceUnavailable }
        self.queue = queue
        let compiled = try NativeMetalPipelineCache.pipelines(for: device)
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
        let encodingStart = DispatchTime.now().uptimeNanoseconds
        let count = snapshot.sourceBubbles.count
        let segmentCount = snapshot.sourceSegments.count
        try rigidState.prepare(snapshot.publicSettings?.rigidPolygons ?? [], bubbleCount: count,
            timeStep: snapshot.configuration.timeStep, candidateLimit: configuration.candidateLimitPerObject)
        let joints = snapshot.publicSettings?.joints ?? []
        if joints.isEmpty {
            // Bez więzów lista identyfikatorów i słownik encji nie są potrzebne, wystarczą liczby.
            try jointState.prepareWithoutJoints(bubbleCount: count,
                bodyCount: snapshot.publicSettings?.rigidPolygons.count ?? 0, iterations: Self.rigidSolverIterationCount)
        } else {
            try jointState.prepare(joints,
                bubbleIDs: snapshot.sourceBubbles.map { ObjectID(rawValue: UInt64(bitPattern: Int64($0.id.rawValue))) },
                bodyIDs: (snapshot.publicSettings?.rigidPolygons ?? []).map { $0.object.descriptor.id },
                iterations: Self.rigidSolverIterationCount)
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
                eventCapacity: max(requestedEventCapacity, persistentState?.eventCapacity ?? 1),
                captureSubsteps: configuration.captureSubsteps)
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
        // Kodowanie nadpisze bufor kandydatów: klucze poprzedniej publikacji przestają być czytelne (jedno przypisanie liczby).
        publishedCandidateCount = 0
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
            shape: SIMD4(contourConfiguration.maxContourSegmentLength, 0,
                         contourConfiguration.contourSurfaceTension, contourConfiguration.positionTolerance))
        state.safetyControl.contents().storeBytes(of: NativeMetalSafetyControl(counts: .zero), as: NativeMetalSafetyControl.self)
        // Bez historii kontaktów (silnik 4.0.0 nie ma cache λ, krawędzi wejścia ani teleportu): rekordy kontaktów końca kroku powstają od zera,
        // więc `limits.w` (liczba rekordów poprzedniego cache) i liczba unieważnień to zero.
        let contactParameters = NativeMetalContactControl(
            limits: SIMD4(nextFrame, 0, UInt32(state.contactCapacity), 0),
            counts: .zero, cache: SIMD4(0, 0, 0, UInt32(configuration.candidateLimitPerObject)),
            thresholds: SIMD4(0, 0, snapshot.configuration.contactTolerance, snapshot.configuration.separationTolerance), cellWidth: .zero)
        state.contactControl.contents().storeBytes(of: contactParameters, as: NativeMetalContactControl.self)
        // Czasy i liczniki pętli podkroków: czas kroku, zero upłyniętego, zero podkroków; `substepControl` jest współdzielony z GPU.
        // Świat bez baniek nie ma podkroków: czas kroku jest od razu upłyniony, więc bramki końca kroku (bryły, sensory) się otwierają.
        state.substepControl.contents().storeBytes(of: NativeMetalSubstepControl(time: SIMD4(snapshot.configuration.timeStep,
            count == 0 ? snapshot.configuration.timeStep : 0, 0, Float(configuration.substepSplitMultiplier))),
                                                   as: NativeMetalSubstepControl.self)
        try forceBuffers.upload(snapshot.publicSettings?.forces ?? NativeForceInput(), device: device)
        memset(state.dispatchStatistics.contents(), 0, state.dispatchStatistics.length)
        memset(state.candidateOverflow.contents(), 0, state.candidateOverflow.length)
        memset(state.endAdjacencyOverflow.contents(), 0, state.endAdjacencyOverflow.length)
        memset(state.contactAssertion.contents(), 0, state.contactAssertion.length)
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

        // Bufor wywołującego dostaje tylko render po końcu kroku (P-B-39); fizyka idzie własnymi buforami solvera: parami
        // (bufor podkroków, bufor końca kroku), commitowanymi bez czekania między sobą (CD-D-18).
        if let commandBuffer {
            guard commandBuffer.device === device, commandBuffer.status == .notEnqueued else {
                throw NativeMetalSolverError.commandSetupFailed
            }
        }
        let descriptor = MTLCommandBufferDescriptor()
        descriptor.retainedReferences = true
        descriptor.errorOptions = .encoderExecutionStatus
        var encoder: MTLComputeCommandEncoder!
        func makeCommand(_ label: String) throws -> MTLCommandBuffer {
            guard let command = queue.makeCommandBuffer(descriptor: descriptor) else { throw NativeMetalSolverError.commandSetupFailed }
            command.label = label
            return command
        }
        func beginCompute(_ command: MTLCommandBuffer, label: String) throws {
            guard let created = command.makeComputeCommandEncoder() else { throw NativeMetalSolverError.commandSetupFailed }
            created.label = label
            encoder = created
        }
        func encodeInputs(_ command: MTLCommandBuffer) throws {
            guard let blit = command.makeBlitCommandEncoder() else { throw NativeMetalSolverError.commandSetupFailed }
            blit.label = "native.inputs"
            if count > 0 {
                blit.copy(from: state.publishedBubbles, sourceOffset: 0, to: state.workingBubbles, destinationOffset: 0, size: count * bubbleStride)
            }
            if segmentCount > 0 {
                blit.copy(from: state.segments, sourceOffset: 0, to: state.workingSegments, destinationOffset: 0, size: segmentCount * segmentStride)
            }
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
            var endMode = UInt32(0)
            encoder.setBytes(&levels, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.setBytes(&endMode, length: MemoryLayout<UInt32>.stride, index: 4)
            encoder.dispatchThreads(.init(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        }
        // Argumenty dyspozycji pośrednich końca kroku (`EndArgument`) w trybie końca kroku, za bramką: w parze niekońcowej bez grup, więc
        // sloty zostają wyzerowane przez `nativePrepareEndGates`, a sloty pętli podkroków nie są ruszane.
        func prepareEndArguments() {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["nativePrepareIndirectArguments"]!)
            for (index, buffer) in [state.control, state.contactControl, state.indirectArguments].enumerated() {
                encoder.setBuffer(buffer, offset: 0, index: index)
            }
            var levels = UInt32(state.scanBlockSums.count)
            var endMode = UInt32(1)
            encoder.setBytes(&levels, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.setBytes(&endMode, length: MemoryLayout<UInt32>.stride, index: 4)
            encoder.dispatchThreadgroups(indirectBuffer: state.endGates,
                indirectBufferOffset: NativeMetalSubstep.EndGate.indirectArguments.rawValue * MemoryLayout<SIMD4<UInt32>>.stride,
                threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        }
        func dispatchContacts(_ name: String, buffers: [MTLBuffer], argument: Int) {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines[name]!)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.dispatchThreadgroups(indirectBuffer: state.indirectArguments, indirectBufferOffset: argument * 16,
                threadsPerThreadgroup: .init(width: 32, height: 1, depth: 1))
        }
        // Dyspozycja pośrednia końca kroku: liczbę grup bierze ze slotu `EndArgument`, który w parze niekońcowej jest zerem.
        func dispatchEndContacts(_ name: String, buffers: [MTLBuffer], argument: NativeMetalSubstep.EndArgument) {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines[name]!)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.dispatchThreadgroups(indirectBuffer: state.indirectArguments,
                indirectBufferOffset: (state.endArgumentBase + argument.rawValue) * MemoryLayout<SIMD4<UInt32>>.stride,
                threadsPerThreadgroup: .init(width: 32, height: 1, depth: 1))
        }
        func endGate(_ gate: NativeMetalSubstep.EndGate) -> NativeMetalDispatchGate {
            NativeMetalDispatchGate(buffer: state.endGates, offset: gate.rawValue * MemoryLayout<SIMD4<UInt32>>.stride)
        }
        let scanBuffers = NativeMetalScanBuffers(values: state.scanValues, offsets: state.scanOffsets,
            blockSums: state.scanBlockSums, blockOffsets: state.scanBlockOffsets, control: state.control,
            contacts: state.contactControl, indirectArguments: state.indirectArguments, overflow: state.candidateOverflow)
        func scan(mode: UInt32, maximum: Int, gate: NativeMetalDispatchGate? = nil) {
            NativeMetalScan.encode(encoder, pipelines: pipelines, buffers: scanBuffers, mode: mode, maximum: maximum,
                                   singleGroup: true, gate: gate)
        }
        // Gotowe liczby grup bramek końca kroku (`nativePrepareEndGates`): CPU zna rozmiar każdej dyspozycji.
        func groups(_ name: String, _ threads: Int) -> UInt32 {
            let pipeline = pipelines[name]!
            let width = min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup)
            return UInt32((max(threads, 0) + width - 1) / width)
        }
        var gateGroups = [UInt32](repeating: 0, count: NativeMetalSubstep.EndGate.allCases.count)
        gateGroups[NativeMetalSubstep.EndGate.region.rawValue] = groups("nativeApplyPublicRegion", count)
        gateGroups[NativeMetalSubstep.EndGate.contactAssertion.rawValue] = groups("nativeAssertContacts", count)
        gateGroups[NativeMetalSubstep.EndGate.mergeEvents.rawValue] = groups("nativeCompactMergeEvents", state.contactCapacity)
        gateGroups[NativeMetalSubstep.EndGate.sensors.rawValue] = groups("nativeCompactSensorEvents", pairCount)
        gateGroups[NativeMetalSubstep.EndGate.missingSensors.rawValue] = groups("nativeCompactMissingSensorEvents", previousSensorPairCount)
        gateGroups[NativeMetalSubstep.EndGate.rigidFinish.rawValue] = groups("nativeRigidFinish", rigidState.count)
        gateGroups[NativeMetalSubstep.EndGate.polygonSensors.rawValue] = groups("nativeCompactPolygonSensorEvents", polygonPairCount)
        gateGroups[NativeMetalSubstep.EndGate.missingPolygonSensors.rawValue] = groups("nativeCompactMissingSensorEvents", previousPolygonSensorPairCount)
        gateGroups[NativeMetalSubstep.EndGate.bubbleBodyContacts.rawValue] = groups("nativeBubbleBodyContacts", rigidState.rowCapacity)
        gateGroups[NativeMetalSubstep.EndGate.contactScan.rawValue] = 1
        gateGroups[NativeMetalSubstep.EndGate.indirectArguments.rawValue] = 1
        gateGroups[NativeMetalSubstep.EndGate.clearAdjacency.rawValue] = groups("nativeClearAdjacency", count)
        gateGroups[NativeMetalSubstep.EndGate.buildAdjacency.rawValue] = groups("nativeBuildAdjacency", count)
        gateGroups[NativeMetalSubstep.EndGate.contactPressure.rawValue] = groups("nativeAccumulateContactPressure", count * state.contourStride)
        gateGroups[NativeMetalSubstep.EndGate.structuralContours.rawValue] = groups("nativeSeedStructuralContours", count * state.contourStride)
        // Kontur i przygotowanie renderu: jedna grupa na bańkę (ścieżki zgrupowane); zapasowe wątek-na-bańkę biegną bez bramki.
        gateGroups[NativeMetalSubstep.EndGate.contour.rawValue] = UInt32(count)
        gateGroups[NativeMetalSubstep.EndGate.renderPreparation.rawValue] = UInt32(count)
        gateGroups[NativeMetalSubstep.EndGate.hitTest.rawValue] = groups("nativeHitTest", snapshot.hitTests.count)
        func dispatchGate(_ pipeline: MTLComputePipelineState, _ gate: NativeMetalSubstep.EndGate) {
            encoder.dispatchThreadgroups(indirectBuffer: state.endGates, indirectBufferOffset: gate.rawValue * MemoryLayout<SIMD4<UInt32>>.stride,
                threadsPerThreadgroup: .init(width: min(pipeline.threadExecutionWidth, pipeline.maxTotalThreadsPerThreadgroup), height: 1, depth: 1))
        }
        // Jądro z efektem ubocznym za bramką końca kroku: bufory i bajty wiąże wywołujący, a liczba grup pochodzi z `nativePrepareEndGates`
        // (zero, dopóki czas kroku nie minął albo klatka przekroczyła limit podkroków).
        func dispatchGated(_ name: String, buffers: [MTLBuffer], gate: NativeMetalSubstep.EndGate,
                           bytes: (MTLComputeCommandEncoder) -> Void = { _ in }) {
            let pipeline = pipelines[name]!
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipeline)
            for (index, buffer) in buffers.enumerated() { encoder.setBuffer(buffer, offset: 0, index: index) }
            bytes(encoder)
            dispatchGate(pipeline, gate)
        }
        func setBytes<T>(_ encoder: MTLComputeCommandEncoder, _ value: T, index: Int) {
            var copy = value
            encoder.setBytes(&copy, length: MemoryLayout<T>.stride, index: index)
        }
        // Tylko pierwsza para: początek kroku. Bryły ruchome liczą się raz na krok (solver brył bez baniek), bańki dostają kontakt z pętli podkroków.
        func encodeStepPrefix() {
            dispatch("nativeBeginStep", buffers: [state.workingBubbles, state.control], threads: count)
            if hasRigidBodies {
                dispatch("nativeRigidPredict", buffers: [rigidState.bodies, rigidState.vertices, rigidState.control,
                    state.control, state.workingSegments, state.safetyControl, rigidState.walls, jointState.ranges, jointState.exclusions],
                    threads: rigidState.count)
                // Tylko pary brył (tryb `.bodies`): kandydaci bańka–bryła powstają przy każdej budowie siatki, z zapasem obwiedni (encodeBroadphase).
                NativeMetalRigidCandidates.encode(encoder, pipelines: pipelines, bodies: rigidState.bodies,
                    bubbles: state.workingBubbles, margins: state.broadphaseMargin, control: rigidState.control,
                    rows: rigidState.candidates, rowCounts: rigidState.rowCounts, overflow: state.candidateOverflow,
                    jointRanges: jointState.ranges, jointPartners: jointState.exclusions, bodyCount: rigidState.count)
                // CCD bryła–bryła po wierszach kandydatów, przed pętlą: faza 1 liczy czas uderzenia, faza 2 cofa bryły.
                dispatch("nativeRigidResolveCCD", buffers: [rigidState.bodies, rigidState.vertices, rigidState.triangles,
                    rigidState.control, rigidState.candidates, rigidState.rowCounts], threads: rigidState.count)
                dispatch("nativeRigidApplyCCD", buffers: [rigidState.bodies, rigidState.control], threads: rigidState.count)
                for _ in 0..<Self.rigidSolverIterationCount {
                    dispatch("nativeRigidContacts", buffers: [rigidState.bodies, rigidState.vertices, rigidState.triangles,
                        rigidState.control, rigidState.contacts, state.safetyControl, rigidState.candidates, rigidState.rowCounts],
                        threads: rigidState.rowCapacity)
                    dispatch("nativeRigidApplyBodies", buffers: [rigidState.bodies, rigidState.control, rigidState.contacts,
                        rigidState.candidates, rigidState.rowCounts], threads: rigidState.count)
                    if hasJoints {
                        dispatch("nativeSolveJoints", buffers: [rigidState.bodies, jointState.records, jointState.corrections,
                            jointState.control, state.control], threads: jointState.count)
                        dispatch("nativeApplyJointBodies", buffers: [rigidState.bodies, jointState.corrections,
                            jointState.references, jointState.ranges, jointState.control], threads: rigidState.count)
                    }
                    dispatch("nativeRigidGuardWalls", buffers: [rigidState.bodies, rigidState.vertices, rigidState.triangles, rigidState.control,
                        jointState.ranges, jointState.exclusions], threads: rigidState.count)
                }
            }
        }
        // Początek każdej pary: a₀, zapas obwiedni i x₀, potem siatka i kandydaci z zapasem (kolejna para zaczyna od przebudowy).
        func encodeBroadphase() {
            NativeMetalSubstepLoop.encodeBroadphaseInputs(encoder, pipelines: pipelines, state: state, forces: forceBuffers, count: count,
                                                          minimumMarginOnly: configuration.minimumMarginOnly)
            dispatchReduction("nativePrepareGrid", buffers: [state.workingBubbles, state.control, state.contactControl, state.broadphaseMargin])
            dispatch("nativeBuildGrid", buffers: [state.workingBubbles, state.control, state.contactControl, state.grid], threads: state.bubbleCapacity)
            NativeMetalGridSort.encode(encoder, pipelines: pipelines, grid: state.grid, capacity: state.bubbleCapacity)
            dispatch("nativeEmitCandidates", buffers: [state.workingBubbles, state.control, state.contactControl,
                state.grid, state.workingSegments, state.candidateRows, state.candidateRowCounts, state.candidateOverflow,
                jointState.ranges, jointState.exclusions, state.broadphaseMargin], threads: count)
            dispatch("nativePrepareCandidateCounts", buffers: [state.control, state.candidateRowCounts, state.scanValues], threads: count * 2)
            scan(mode: 0, maximum: max(1, count * 2))
            prepareIndirectArguments()
            dispatch("nativeCompactCandidates", buffers: [state.control, state.contactControl, state.candidateRows,
                state.candidateRowCounts, state.candidates, state.scanOffsets, state.dispatchStatistics],
                threads: count * Self.candidateLimitPerObject)
            // Sąsiedztwo z kandydatów (także tych, które jeszcze nie dotykają), potem pętla podkroków zamiast predykcji i XPBD.
            dispatch("nativeClearAdjacency", buffers: [state.control, state.adjacencyCounts], threads: count)
            dispatchContacts("nativeEmitCandidateAdjacency", buffers: [state.contactControl, state.candidates, state.adjacency,
                state.adjacencyCounts, state.candidateOverflow], argument: 0)
            // Kandydaci bańka–bryła (statyczne koło i kapsuła, bryła kinematyczna) z zapasem obwiedni: osobne wiersze brył, potem rodzaj 2 w wierszach
            // sąsiedztwa baniek. Droga bryły w kroku jest już znana (poza początku i końca kroku), więc obwiednia bryły nie zależy od przebudowy.
            if hasRigidBodies && count > 0 {
                NativeMetalRigidCandidates.encode(encoder, pipelines: pipelines, bodies: rigidState.bodies,
                    bubbles: state.workingBubbles, margins: state.broadphaseMargin, control: rigidState.bubbleControl,
                    rows: rigidState.bubbleCandidates, rowCounts: rigidState.bubbleRowCounts, overflow: state.candidateOverflow,
                    jointRanges: jointState.ranges, jointPartners: jointState.exclusions, bodyCount: rigidState.count)
                dispatch("nativeEmitRigidAdjacency", buffers: [rigidState.bubbleCandidates, rigidState.bubbleRowCounts,
                    rigidState.bubbleControl, state.contactControl, state.adjacency, state.adjacencyCounts, state.candidateOverflow],
                    threads: rigidState.rowCapacity)
            }
            dispatch("nativeBuildAdjacency", buffers: [state.control, state.contactControl,
                state.adjacency, state.adjacencyCounts, state.candidateOverflow], threads: count)
        }
        // Ścieżka jednej dyspozycji (CD-D-27): ta sama budowa, ale jedną grupą wątków w jądrze `nativeBroadphaseSingleGroup` (do zadania 37 jeszcze
        // z parami buforów). Wskaźniki idą jedną strukturą (bufor argumentów), bo jądro ma ponad 31 buforów; adresy GPU w kolejności pól struktury
        // `NativeBroadphaseBuffers`, a `useResource` udostępnia każdy bufor. Bryły są kandydatami tylko przy `hasRigidBodies`.
        func encodeBroadphaseSingleGroup() {
            guard count > 0 else { return }
            let pipeline = pipelines["nativeBroadphaseSingleGroup"]!
            let buffers: [MTLBuffer] = [state.workingBubbles, state.control, state.contactControl, state.grid, state.workingSegments,
                state.candidateRows, state.candidateRowCounts, state.candidateOverflow, jointState.ranges, jointState.exclusions,
                state.broadphaseMargin, state.referencePositions, state.nonContactAcceleration, forceBuffers.control!, forceBuffers.fields!,
                forceBuffers.fieldVertices!, forceBuffers.fieldObjectIDs!, forceBuffers.bands!, forceBuffers.motors!, state.substepControl,
                rigidState.bodies, rigidState.bubbleControl, rigidState.bubbleCandidates, rigidState.bubbleRowCounts, state.scanValues,
                state.scanOffsets, state.candidates, state.dispatchStatistics, state.adjacency, state.adjacencyCounts]
            var table = buffers.map(\.gpuAddress)
            var parameters = SIMD4<UInt32>(configuration.minimumMarginOnly ? 1 : 0, UInt32(configuration.gridHashBucketCount),
                                           hasRigidBodies ? 1 : 0, 0)
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&table, length: table.count * MemoryLayout<UInt64>.stride, index: 0)
            encoder.setBytes(&parameters, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 1)
            var seen = Set<ObjectIdentifier>()
            for buffer in buffers where seen.insert(ObjectIdentifier(buffer)).inserted { encoder.useResource(buffer, usage: [.read, .write]) }
            encoder.setThreadgroupMemoryLength(NativeMetalSubstep.singleGroupMemoryLength, index: 0)
            let width = Self.singleGroupWidth(pipeline)
            encoder.dispatchThreadgroups(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
        }
        // Koniec kroku: jądra bez efektu ubocznego liczą się w każdym buforze końca kroku, a z efektem (region, zdarzenia, czujniki,
        // zakończenie brył, asercja) idą bramkami, więc biegną raz na krok, w ostatnim buforze końca kroku.
        func encodeEndOfStep() {
            dispatchPrepareEndGates()
            // Sloty argumentów dyspozycji pośrednich z liczników kandydatów (nie zmieniają się do końca kroku); w parze niekońcowej bez grup.
            prepareEndArguments()
            // Region (zawinięcie `.wrap`) jako pierwszy, za bramką: to jedyne przesunięcie środka bańki poza siłami (CD-D-19). Rekordy kontaktów,
            // asercja i kontur liczą się więc już z położenia po regionie.
            if snapshot.publicSettings != nil {
                dispatchGated("nativeApplyPublicRegion", buffers: [state.workingBubbles, state.control, state.safetyControl], gate: .region)
            }
            // Rekordy kontaktów końca kroku z końcowych położeń (zdarzenia, scalanie i kontur czytają je dalej): kandydaci → kontakty w
            // zasięgu rozdzielenia → rekordy bez historii (`limits.w` = 0, więc dopasowanie do poprzedniego cache niczego nie znajduje).
            if hasRigidBodies && count > 0 {
                dispatchGated("nativeBubbleBodyContacts", buffers: [state.workingBubbles, rigidState.bodies, rigidState.vertices,
                    rigidState.triangles, rigidState.bubbleCandidates, rigidState.bubbleRowCounts, rigidState.bubbleControl, state.control,
                    rigidState.bubbleContacts], gate: .bubbleBodyContacts)
            }
            dispatchEndContacts("nativeBuildContacts", buffers: [state.workingBubbles, state.workingSegments, state.contactControl,
                state.candidates, state.contacts], argument: .buildContacts)
            dispatchEndContacts("nativePrepareContactFlags", buffers: [state.contacts, state.contactControl, state.scanValues],
                                argument: .prepareContactFlags)
            scan(mode: 1, maximum: state.contactCapacity, gate: endGate(.contactScan))
            dispatchEndContacts("nativeCompactActiveContacts", buffers: [state.contacts, state.workingCache, state.contactControl, state.scanOffsets],
                                argument: .compactActiveContacts)
            prepareEndArguments()
            // Sąsiedztwo z rekordów kontaktów (kontur ciśnienia) liczy odrzucenia do osobnego licznika: kandydat odrzucony przy budowie siatki
            // jest już policzony w `candidateOverflow`.
            dispatchGated("nativeClearAdjacency", buffers: [state.control, state.adjacencyCounts], gate: .clearAdjacency)
            dispatchEndContacts("nativeEmitAdjacency", buffers: [state.workingBubbles, state.workingSegments, state.workingCache,
                state.control, state.contactControl, state.adjacency, state.contactEndpoints, state.dispatchStatistics,
                state.adjacencyCounts, state.endAdjacencyOverflow], argument: .emitAdjacency)
            dispatchGated("nativeBuildAdjacency", buffers: [state.control, state.contactControl,
                state.adjacency, state.adjacencyCounts, state.endAdjacencyOverflow], gate: .buildAdjacency)
            // Impuls siły kontaktu w rekordach końca kroku (`response.x`): zdarzenie kontaktu czyta go z rekordu.
            dispatchEndContacts("nativeContactImpulses", buffers: [state.workingBubbles, state.workingSegments, state.workingCache,
                state.control, state.contactControl], argument: .contactImpulses)
            if snapshot.publicSettings != nil {
                dispatchGated("nativeCompactMergeEvents", buffers: [state.workingBubbles, state.workingCache, state.control,
                    state.contactControl, state.eventCount, state.eventRecords], gate: .mergeEvents) {
                    setBytes($0, UInt32(requestedEventCapacity), index: 6)
                }
            }
            dispatchEndContacts("nativeCheckFinite", buffers: [state.workingBubbles, state.workingSegments, state.workingCache,
                state.control, state.contactControl, state.safetyControl],
                argument: .checkFinite)
            // Asercja kontaktu po regionie i skończoności, za bramką; zgłasza naruszenie w rekordzie, nie odrzuca kroku (G6-AC2).
            NativeMetalSubstepLoop.bindAssertContacts(encoder, pipelines: pipelines, state: state, rigid: rigidState, bodyCount: rigidState.count)
            dispatchGate(pipelines["nativeAssertContacts"]!, .contactAssertion)
            dispatchGated("nativeAccumulateContactPressure", buffers: [state.workingBubbles, state.workingSegments,
                state.workingCache, state.control, state.contactControl, state.contourControl, state.contourScratch,
                state.workingContourCounts, state.adjacency, state.adjacencyCounts, state.safetyControl], gate: .contactPressure)
            if !structuralSources.isEmpty {
                dispatchGated("nativeSeedStructuralContours", buffers: [state.workingBubbles, structuralHeaderBuffer,
                    structuralSourceBuffer, structuralClipBuffer, state.contourScratch, state.workingContourCounts,
                    state.control, state.contourControl, state.publishedBubbles,
                    state.publishedDeformation, state.publishedContourCounts], gate: .structuralContours)
            }
            // Liczba przejść jest nieparzysta: wynik pozostaje w roboczym buforze deformacji.
            NativeMetalContourSmoothing.encode(encoder, pipelines: pipelines, input: state.contourScratch,
                output: state.workingDeformation, counts: state.workingContourCounts, control: state.control,
                contour: state.contourControl, safety: state.safetyControl, bubbleCount: count,
                stride: state.contourStride, fused: true, gate: endGate(.contour))
            NativeMetalRenderPreparation.encode(encoder, pipelines: pipelines, bubbles: state.workingBubbles,
                deformation: state.workingDeformation, counts: state.workingContourCounts, points: state.workingContourPoints,
                packets: state.renderPackets, control: state.control, contour: state.contourControl,
                safety: state.safetyControl, bubbleCount: count, stride: state.contourStride, grouped: true,
                gate: endGate(.renderPreparation))
            if snapshot.publicSettings != nil {
                if pairCount > 0 {
                    dispatchGated("nativeCompactSensorEvents", buffers: [state.workingBubbles, state.control, sensorRecordBuffer,
                        sensorVertexBuffer, sensorAllowedBuffer, previousSensorPairBuffer,
                        currentSensorPairs, state.eventCount, state.eventRecords], gate: .sensors) {
                        setBytes($0, SIMD4(UInt32(sensors.count), UInt32(previousSensorPairCount), UInt32(requestedEventCapacity), UInt32(0)), index: 9)
                    }
                }
                if previousSensorPairCount > 0 {
                    dispatchGated("nativeCompactMissingSensorEvents", buffers: [previousSensorPairBuffer, currentSensorPairs,
                        state.eventCount, state.eventRecords], gate: .missingSensors) {
                        setBytes($0, SIMD4(UInt32(previousSensorPairCount), UInt32(pairCount), UInt32(requestedEventCapacity), UInt32(0)), index: 4)
                    }
                }
            }
            if hasRigidBodies {
                dispatchGated("nativeRigidFinish", buffers: [rigidState.bodies, rigidState.vertices, rigidState.control,
                    state.control, state.safetyControl], gate: .rigidFinish)
            }
            if polygonPairCount > 0 {
                dispatchGated("nativeCompactPolygonSensorEvents", buffers: [rigidState.bodies, rigidState.vertices, sensorRecordBuffer,
                    sensorVertexBuffer, polygonSensorAllowedBuffer, previousPolygonSensorPairBuffer,
                    currentPolygonSensorPairs, state.eventCount, state.eventRecords], gate: .polygonSensors) {
                    setBytes($0, SIMD4(UInt32(sensors.count), UInt32(previousPolygonSensorPairCount), UInt32(requestedEventCapacity),
                                       UInt32(rigidInputs.count)), index: 9)
                }
            }
            if previousPolygonSensorPairCount > 0 {
                dispatchGated("nativeCompactMissingSensorEvents", buffers: [previousPolygonSensorPairBuffer, currentPolygonSensorPairs,
                    state.eventCount, state.eventRecords], gate: .missingPolygonSensors) {
                    setBytes($0, SIMD4(UInt32(previousPolygonSensorPairCount), UInt32(polygonPairCount), UInt32(requestedEventCapacity),
                                       UInt32(1)), index: 4)
                }
            }
            if !snapshot.hitTests.isEmpty {
                // Na buforach roboczych tego kroku, po ostatnim kernelu, który zmienia kontury i pozy brył.
                dispatchGated("nativeHitTest", buffers: [hitTestPoints, state.workingContourPoints, state.workingContourCounts,
                    state.workingBubbles, rigidState.count > 0 ? rigidState.bodies : state.eventRecords,
                    rigidState.count > 0 ? rigidState.vertices : state.eventRecords,
                    rigidState.count > 0 ? rigidState.triangles : state.eventRecords, state.control,
                    hitTestCounts, hitTestResultBuffer], gate: .hitTest)
            }
        }
        func dispatchPrepareEndGates() {
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["nativePrepareEndGates"]!)
            encoder.setBuffer(state.substepControl, offset: 0, index: 0)
            encoder.setBuffer(state.endGates, offset: 0, index: 1)
            gateGroups.withUnsafeBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 2) }
            var gateCount = UInt32(gateGroups.count)
            var endCount = UInt32(NativeMetalSubstep.EndArgument.allCases.count)
            encoder.setBytes(&gateCount, length: MemoryLayout<UInt32>.stride, index: 3)
            encoder.setBuffer(state.indirectArguments, offset: state.endArgumentBase * MemoryLayout<SIMD4<UInt32>>.stride, index: 4)
            encoder.setBytes(&endCount, length: MemoryLayout<UInt32>.stride, index: 5)
            let width = max(gateGroups.count, Int(endCount))
            encoder.dispatchThreads(.init(width: width, height: 1, depth: 1), threadsPerThreadgroup: .init(width: width, height: 1, depth: 1))
        }
        let encodingEnd = DispatchTime.now().uptimeNanoseconds
        let loop = try await NativeMetalSubstepLoop.run(state: state, previousFrameSubsteps: previousFrameSubstepCount,
            bubbleCount: count, forceMultipleDispatches: configuration.forceMultipleDispatches,
            executor: commandExecutor, prepareContinuation: {
                // Przebudowa siatki w kolejnej parze zaczyna od zera liczników kontaktów i kandydatów, jak pierwsza para; czasy i liczniki
                // klatki zostają. Kontynuacja bez przebudowy ich nie rusza: czyta sąsiedztwo z poprzedniej pary.
                state.contactControl.contents().storeBytes(of: contactParameters, as: NativeMetalContactControl.self)
            },
            encodePair: { pair, substeps, rebuild, path in
                let first = pair == 0
                let stepsCommand = try makeCommand("native.frame.step.\(scenarioStep).substeps.\(pair)")
                if first { try encodeInputs(stepsCommand) }
                try beginCompute(stepsCommand, label: "native.substeps")
                if first { encodeStepPrefix() }
                if rebuild { if path == .singleDispatch { encodeBroadphaseSingleGroup() } else { encodeBroadphase() } }
                NativeMetalSubstepLoop.encode(encoder, pipelines: pipelines, state: state, forces: forceBuffers, rigid: rigidState, count: count,
                                              capture: configuration.captureSubsteps, substeps: substeps, initialForces: rebuild,
                                              diagnostics: NativeMetalSubstepDiagnostics(injection: configuration.injectedSubstepState,
                                                  assertEverySubstep: configuration.assertEverySubstep, bodyCount: rigidState.count))
                encoder.endEncoding()
                let endCommand = try makeCommand("native.frame.step.\(scenarioStep).end.\(pair)")
                try beginCompute(endCommand, label: "native.end")
                encodeEndOfStep()
                encoder.endEncoding()
                if first {
                    // Od pierwszego commitu krok pisze stronę roboczą, która w opublikowanym uchwycie jest stroną t−1.
                    publishedRenderHandoff?.invalidatePreviousContours()
                }
                return (stepsCommand, endCommand)
            })
        // Szerokość grupy jądra pętli podkroków: 0 w ścieżce wielu dyspozycji (A11 może dać mniej niż Mac).
        let singleGroupWidth = loop.executionPath == .singleDispatch ? Self.singleGroupWidth(pipelines["nativeBroadphaseSingleGroup"]!) : 0
        let timing = NativeMetalCommandTiming(gpuMilliseconds: loop.substepGPUMilliseconds + loop.endGPUMilliseconds)
        previousFrameSubstepCount = Int(state.substepControl.contents().load(as: NativeMetalSubstepControl.self).counts.y)
        let waitingEnd = DispatchTime.now().uptimeNanoseconds
        let contactResult = state.contactControl.contents().load(as: NativeMetalContactControl.self)
        let safetyResult = state.safetyControl.contents().load(as: NativeMetalSafetyControl.self)
        let substepResult = state.substepControl.contents().load(as: NativeMetalSubstepControl.self)
        var profile = NativeMetalFrameProfile()
        profile.commandBufferCount = 2 * loop.pairCount
        profile.encoderCount = 2 * loop.pairCount
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
        var diagnostics = NativeMetalFrameTelemetry(backend: .nativeMetal, commandBufferCount: 2 * loop.pairCount, encoderCount: 2 * loop.pairCount,
            contactCount: Int(contactResult.counts.y), didEncounterNonFinite: safetyResult.counts.w & 1 != 0,
            gpuMilliseconds: timing.gpuMilliseconds, substepCount: Int(substepResult.counts.y),
            gridRebuildCount: loop.rebuildCount, physicsGPUMilliseconds: loop.substepGPUMilliseconds,
            contourGPUMilliseconds: loop.endGPUMilliseconds, substepBufferCount: loop.pairCount,
            executionPath: loop.executionPath, singleGroupWidth: singleGroupWidth)
        func rejectSafety(_ reason: NativeMetalWorldError, guardCause: NativeMetalGuardCause? = nil,
                          detail: NativeMetalFailureDetail? = nil) -> NativeMetalSafetyFailure {
            .init(reason: reason, telemetry: diagnostics, profile: profile, guardCause: guardCause, detail: detail)
        }
        // Limit podkroków sprawdza się najpierw (R3): obiekt i człon h pochodzą z ostatniego podkroku klatki.
        guard substepResult.counts.w == 0 else {
            throw rejectSafety(.substepLimitExceeded, detail: NativeMetalFailureDetail(objectIDs: [substepResult.limiter.x],
                limitingTerm: NativeMetalSubstep.Term(rawValue: substepResult.limiter.y).map(Self.term)))
        }
        guard safetyResult.counts.w & 1 == 0 else { throw rejectSafety(.nonFinite) }
        // Asercja kontaktu biegnie po regionie i nie odrzuca kroku: świat przechodzi w `worldFailed` (G6-AC2, G6-AC4).
        let assertion = state.contactAssertion.contents().load(as: NativeMetalContactAssertion.self)
        if let kind = NativeMetalContactAssertion.Kind(rawValue: assertion.state.x) {
            throw rejectSafety(.contactViolation, detail: Self.violationDetail(assertion, kind: kind, segments: snapshot.sourceSegments))
        }
        guard safetyResult.counts.w & 2 == 0 else {
            // Bit przyczyny zapala się zawsze razem z bitem 2 (strażnik brył).
            throw rejectSafety(.guardFailure, guardCause: safetyResult.counts.w & 16 != 0 ? .rigidRotationBudget : nil)
        }
        let cacheRecords = state.workingCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)
        let completedCache = Array(UnsafeBufferPointer(start: cacheRecords, count: Int(contactResult.counts.z)))
        guard completedCache.allSatisfy({ $0.geometry.x.isFinite && $0.geometry.y.isFinite
            && $0.geometry.z.isFinite && $0.geometry.w.isFinite && $0.lambda.isFinite
            && $0.response.y.isFinite })
        else { throw rejectSafety(.nonFinite) }
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
        var effectiveRadii: [Float] = []
        var bubbleBounds: [SIMD4<Float>?] = []
        effectiveRadii.reserveCapacity(bubbles.count)
        bubbleBounds.reserveCapacity(bubbles.count)
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
            // Kontur jest tylko rysowany: jego zła wartość nie odrzuca kroku, host naprawia opublikowane wartości. Skończoność
            // fizyki sprawdził już `nativeCheckFinite`, a spójność pakietu z rekordem (wyżej) zostaje.
            // Deformacja nieskończona albo spoza [0, 1] nie wchodzi do statystyk.
            let deformation = packets[index].deformation.x
            if deformation.isFinite, deformation >= 0, deformation <= 1 {
                if deformation * bubbles[index].targetRadius > contourConfiguration.positionTolerance { deformationCount += 1 }
                maximumRelativeDeformation = max(maximumRelativeDeformation, deformation)
            }
            if readsContours { contours[bubbles[index].id] = points }
            // Promień efektywny nieskończony albo spoza [0, targetRadius] staje się `targetRadius`.
            let measuredRadius = packets[index].deformation.y
            effectiveRadii.append(measuredRadius.isFinite && measuredRadius >= 0 && measuredRadius <= bubbles[index].targetRadius
                ? measuredRadius : bubbles[index].targetRadius)
            // Obwiednia nieskończona albo odwrócona staje się nil: wtedy obwiednię daje koło bańki.
            let bounds = records[index].bounds
            bubbleBounds.append((0..<4).allSatisfy({ bounds[$0].isFinite }) && bounds.x <= bounds.z && bounds.y <= bounds.w
                ? bounds : nil)
            renderData.append(packets[index].geometry)
        }
        if collectDispatchStatistics {
            let pipelineCounts = state.dispatchStatistics.contents().advanced(by: 32).load(as: SIMD4<UInt32>.self)
            profile.stageGPUWorkItemCounts = ["adjacencyRecords": Int(pipelineCounts.x)]
        }
        let report = NativeSolverReport(maximumPenetration: contacts.map(\.penetration).max() ?? 0,
            deformationCount: deformationCount, maximumRelativeDeformation: maximumRelativeDeformation,
            candidatePairCount: Int(contactResult.counts.x), generatedContactCount: contacts.count,
            totalMilliseconds: milliseconds(waitingEnd - encodingStart), hasNonFiniteState: false)
        var frame = NativeSolverFrame(bubbles: bubbles, contacts: contacts, report: report,
            telemetry: NativeMetalFrameTelemetry(backend: .nativeMetal, commandBufferCount: 2 * loop.pairCount,
                encoderCount: 2 * loop.pairCount, contactCount: contacts.count, gpuMilliseconds: timing.gpuMilliseconds,
                substepCount: Int(substepResult.counts.y), gridRebuildCount: loop.rebuildCount,
                physicsGPUMilliseconds: loop.substepGPUMilliseconds, contourGPUMilliseconds: loop.endGPUMilliseconds,
                substepBufferCount: loop.pairCount, executionPath: loop.executionPath,
                singleGroupWidth: singleGroupWidth),
            profile: profile, contours: contours, renderData: renderData,
            bubbleEffectiveRadii: effectiveRadii, bubbleBoundsRecords: bubbleBounds, isComplete: true)
        if !snapshot.hitTests.isEmpty {
            let records = hitTestResultBuffer.contents().bindMemory(to: NativeHitTestResult.self, capacity: snapshot.hitTests.count)
            frame.hitTestResults = (0..<snapshot.hitTests.count).map { index in
                records[index].found == 0 ? nil : ObjectID(rawValue: records[index].identity)
            }
        }
        let overflowCounters = state.candidateOverflow.contents().load(as: SIMD4<UInt32>.self)
        frame.contactCandidateOverflowCount = loop.candidateOverflowCount
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
        // Render po końcu kroku (P-B-39): bufor końca kroku już się wykonał, więc hak widzi kontury i bańki kroku, a bufor wywołującego
        // zawiera tylko render. Odrzucony krok (limit, wartości nieskończone, błąd haka) zostawia ten bufor niezatwierdzony.
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
        if let commandBuffer {
            // Drugie czekanie CPU w klatce (CD-D-18): na bufor renderu wywołującego. Leży po `waitingEnd`, więc jest częścią publikacji.
            let renderWaitStart = DispatchTime.now().uptimeNanoseconds
            _ = try await commandExecutor.complete(commandBuffer)
            frame.profile.renderWaitMilliseconds = milliseconds(DispatchTime.now().uptimeNanoseconds - renderWaitStart)
        }
        // Synchroniczna publikacja dopiero po pomyślnym wykonaniu i readbacku.
        rigidState.publish(rigidResult.objects)
        publishedPolygons = rigidResult.objects
        publishedDriveContacts = driveContacts
        publishedRigidContacts = rigidContacts
        removedPolygons = rigidResult.removed
        wrappedPolygons = rigidResult.wrapped
        let previousIDs = previousPublicationBubbleIDs
        let hadPreviousPublication = lastSnapshot != nil
        capturedSubsteps = configuration.captureSubsteps
            ? state.capturedSubsteps(bubbleIDs: snapshot.sourceBubbles.map { UInt64(bitPattern: Int64($0.id.rawValue)) }) : []
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

    private static func term(_ term: NativeMetalSubstep.Term) -> NativeMetalSubstepTerm {
        switch term {
        case .remainingTime: return .remainingTime
        case .stiffness: return .stiffness
        case .distance: return .distance
        case .margin: return .margin
        }
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
        let stages: [String: MTLComputePipelineState]
    }

    private static var compiled: [UInt64: Compiled] = [:]

    /// Kernele `nativeScanBlocks`, `nativeAddScanBlockOffsets`, `nativeFinishScan`
    /// (oraz `nativeGenerateContours`, `nativePrepareRenderData`) obsługują dawne ścieżki,
    /// które produkcja pomija; zostają jako wzorzec bit w bit dla `NativeMetalChainKernelTests`.
    static let stageNames: [String] = ["nativePrepareGrid", "nativeBuildGrid", "nativeSortGrid", "nativeSortGridChunk", "nativeEmitCandidates",
        "nativePrepareCandidateCounts", "nativeCompactCandidates", "nativeBuildContacts",
        "nativePrepareContactFlags", "nativeCompactActiveContacts",
        "nativeScanBlocks", "nativePrepareIndirectArguments",
        "nativeAddScanBlockOffsets", "nativeFinishScan", "nativeScanSingleGroup", "nativeClearAdjacency", "nativeEmitAdjacency", "nativeBuildAdjacency",
        "nativeContactForces", "nativeContactImpulses", "nativeAccelerationWithoutContacts", "nativeBroadphaseMargin",
        "nativeReduceSubstep", "nativeIntegrateSubstep", "nativeAssertContacts", "nativeInjectSubstepState", "nativePrepareEndGates", "nativeBeginStep",
        "nativeEmitCandidateAdjacency", "nativeEmitRigidAdjacency", "nativeBubbleBodyContacts", "nativeBroadphaseSingleGroup",
        "nativeCheckFinite",
        "nativeAccumulateContactPressure", "nativeSeedStructuralContours", "nativeGenerateContours", "nativeGenerateContoursFused", "nativePrepareRenderData", "nativePrepareRenderDataGrouped",
        "nativeApplyPublicRegion",
        "nativeCompactMergeEvents",
        "nativeCompactSensorEvents",
        "nativeCompactPolygonSensorEvents",
        "nativeCompactMissingSensorEvents",
        "nativeRigidPredict", "nativeRigidEmitCandidates", "nativeRigidContacts", "nativeRigidApplyBodies", "nativeRigidGuardWalls", "nativeRigidFinish",
        "nativeRigidResolveCCD", "nativeRigidApplyCCD", "nativeSolveJoints", "nativeApplyJointBodies",
        "nativeHitTest"]

    static func pipelines(for device: MTLDevice) throws -> Compiled {
        if let cached = compiled[device.registryID] { return cached }
        let source = try NativeMetalShaderSource.solverSource()
        let options = MTLCompileOptions()
        // Finite jest kontraktem bezpieczeństwa: fast-math zakłada jego spełnienie.
        options.fastMathEnabled = false
        let library = try device.makeLibrary(source: source, options: options)
        var stages: [String: MTLComputePipelineState] = [:]
        for name in stageNames {
            guard let function = library.makeFunction(name: name) else { throw NativeMetalSolverError.resourceUnavailable }
            stages[name] = try device.makeComputePipelineState(function: function)
        }
        let result = Compiled(stages: stages)
        compiled[device.registryID] = result
        return result
    }
}

/// Wczytuje dołączone pliki `.metal-source` kompilowane w czasie działania.
enum NativeMetalShaderSource {
    static let solverFiles = ["NativeGeometryKernels", "NativeContactKernels", "NativeForceKernels", "NativePostSolveKernels"]

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
