import Foundation
import Metal
import BubblePhysicsReference

enum NativeMetalSolverError: Error {
    case resourceUnavailable, allocationFailed, commandSetupFailed, commandFailed(String), invalidSnapshot
}

struct NativeMetalCommandTiming {
    let gpuMilliseconds: Double
}

@MainActor
protocol NativeMetalCommandExecuting {
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
    let contactCache: MTLBuffer
    let scratch: MTLBuffer
    let segmentsPing: MTLBuffer
    let segmentsPong: MTLBuffer
    let bubbleUpdates: MTLBuffer
    let segmentUpdates: MTLBuffer
    let control: MTLBuffer
    let renderPackets: MTLBuffer
    private var publishedIsPing = true
    var publishedBubbles: MTLBuffer { publishedIsPing ? bubblesPing : bubblesPong }
    var workingBubbles: MTLBuffer { publishedIsPing ? bubblesPong : bubblesPing }
    var segments: MTLBuffer { publishedIsPing ? segmentsPing : segmentsPong }
    var workingSegments: MTLBuffer { publishedIsPing ? segmentsPong : segmentsPing }

    init(device: MTLDevice, bubbleCount: Int, segmentCount: Int) throws {
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
        contactCache = try buffer("contactCache", bubbleCapacity, MemoryLayout<NativeMetalContactCache>.stride)
        scratch = try buffer("scratch", bubbleCapacity, MemoryLayout<SIMD4<Float>>.stride)
        renderPackets = try buffer("renderPackets", bubbleCapacity, MemoryLayout<NativeMetalRenderPacket>.stride)
        control = try buffer("control", 1, MemoryLayout<NativeMetalControl>.stride)
    }

    func publish() { publishedIsPing.toggle() }
}

/// Pierwszy etap runtime: trwały stan GPU i predykcja. Klatka jest niepełna,
/// dopóki kolejne zadania nie dodadzą kontaktów, solvera i walidacji publikacji.
@MainActor
final class NativeMetalSolver: NativeMetalFrameExecuting {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let predict: MTLComputePipelineState
    private let commandExecutor: any NativeMetalCommandExecuting
    private var inFlight = false
    private var lastSnapshot: NativeMetalSnapshot?
    private(set) var persistentState: NativeMetalPersistentState?
    private(set) var publishedFrame: NativeMetalWorldFrame?

    init(device: MTLDevice, commandExecutor: (any NativeMetalCommandExecuting)? = nil) throws {
        self.device = device
        self.commandExecutor = commandExecutor ?? NativeMetalCommandExecutor()
        guard let queue = device.makeCommandQueue(),
              let url = Bundle.module.url(forResource: "NativeGeometryKernels", withExtension: "metal-source")
        else { throw NativeMetalSolverError.resourceUnavailable }
        self.queue = queue
        let library = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
        guard let function = library.makeFunction(name: "nativePredict")
        else { throw NativeMetalSolverError.resourceUnavailable }
        predict = try device.makeComputePipelineState(function: function)
    }

    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        try await executeFrame(snapshot: .init(world: world, previous: lastSnapshot), scenarioStep: scenarioStep)
    }

    func executeFrame(snapshot: NativeMetalSnapshot, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        guard !inFlight else { throw NativeMetalWorldError.frameInFlight }
        inFlight = true
        defer { inFlight = false }
        let encodingStart = DispatchTime.now().uptimeNanoseconds
        let count = snapshot.sourceBubbles.count
        let segmentCount = snapshot.sourceSegments.count
        guard count <= Int(UInt32.max), segmentCount <= Int(UInt32.max),
              snapshot.previousBubbles == nil || (snapshot.previousBubbles == lastSnapshot?.sourceBubbles
                  && snapshot.previousSegments == lastSnapshot?.sourceSegments)
        else { throw NativeMetalSolverError.invalidSnapshot }

        // Każda alokacja odbywa się przed utworzeniem command buffera.
        let state: NativeMetalPersistentState
        if let existing = persistentState, existing.bubbleCapacity >= count, existing.segmentCapacity >= segmentCount {
            state = existing
        } else {
            state = try NativeMetalPersistentState(device: device,
                bubbleCount: max(count, persistentState?.bubbleCapacity ?? 0),
                segmentCount: max(segmentCount, persistentState?.segmentCapacity ?? 0))
            if let previous = persistentState {
                // Nie ma klatki w locie. Kopiujemy ukończony stan do nowych shared buffers.
                memcpy(state.publishedBubbles.contents(), previous.publishedBubbles.contents(),
                       min(state.publishedBubbles.length, previous.publishedBubbles.length))
                memcpy(state.contactCache.contents(), previous.contactCache.contents(),
                       min(state.contactCache.length, previous.contactCache.length))
                memcpy(state.segments.contents(), previous.segments.contents(),
                       min(state.segments.length, previous.segments.length))
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
        let parameters = NativeMetalControl(counts: SIMD4(UInt32(count), UInt32(segmentCount), UInt32(truncatingIfNeeded: scenarioStep), 0),
            physics: SIMD4(snapshot.configuration.timeStep, snapshot.configuration.linearDamping, snapshot.configuration.angularDamping, 0))
        state.control.contents().storeBytes(of: parameters, as: NativeMetalControl.self)

        let descriptor = MTLCommandBufferDescriptor()
        descriptor.retainedReferences = true
        descriptor.errorOptions = .encoderExecutionStatus
        guard let command = queue.makeCommandBuffer(descriptor: descriptor),
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
        for remap in snapshot.bubbleRemaps {
            blit.copy(from: state.publishedBubbles, sourceOffset: remap.sourceIndex * bubbleStride,
                      to: state.workingBubbles, destinationOffset: remap.destinationIndex * bubbleStride, size: bubbleStride)
        }
        for change in snapshot.bubbleChanges {
            blit.copy(from: state.bubbleUpdates, sourceOffset: change.index * bubbleStride,
                      to: state.workingBubbles, destinationOffset: change.index * bubbleStride, size: bubbleStride)
        }
        for change in snapshot.segmentChanges {
            blit.copy(from: state.segmentUpdates, sourceOffset: change.index * segmentStride,
                      to: state.workingSegments, destinationOffset: change.index * segmentStride, size: segmentStride)
        }
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
        encoder.endEncoding()
        let encodingEnd = DispatchTime.now().uptimeNanoseconds
        // Jedyny await/commit: wszystkie etapy zostały już zakodowane.
        let timing = try await commandExecutor.complete(command)
        let waitingEnd = DispatchTime.now().uptimeNanoseconds
        var bubbles = snapshot.sourceBubbles
        let records = state.workingBubbles.contents().bindMemory(to: NativeMetalBubble.self, capacity: state.bubbleCapacity)
        for index in bubbles.indices {
            guard records[index].identity.x == Int64(bubbles[index].id.rawValue) else { throw NativeMetalSolverError.invalidSnapshot }
            records[index].unpack(into: &bubbles[index])
        }
        guard !bubbles.contains(where: { !$0.center.isFinite || !$0.previousCenter.isFinite || !$0.velocity.isFinite
            || !$0.rotation.isFinite || !$0.angularVelocity.isFinite }) else { throw NativeMetalWorldError.invalidFrame }
        var profile = NativeMetalFrameProfile()
        profile.commandBufferCount = 1
        profile.encoderCount = 2
        profile.hostEncodingMilliseconds = milliseconds(encodingEnd - encodingStart)
        profile.hostWaitingMilliseconds = milliseconds(waitingEnd - encodingEnd)
        profile.stageGPUMilliseconds = ["prediction": timing.gpuMilliseconds]
        let report = ReferenceWorldStepReport(solver: .init(iterations: 0, maximumPenetration: 0, converged: false,
            didReachIterationLimit: false, positionCorrectionCount: 0, deformationCount: 0),
            candidatePairCount: 0, generatedContactCount: 0, persistentContactCount: 0, toiTestCount: 0,
            sideCorrectionCount: 0, ccdBudgetExhaustionCount: 0, predictionMilliseconds: timing.gpuMilliseconds,
            broadPhaseMilliseconds: 0, contactMilliseconds: 0, solverMilliseconds: 0,
            totalMilliseconds: milliseconds(waitingEnd - encodingStart), hasNonFiniteState: false)
        let frame = NativeMetalWorldFrame(bubbles: bubbles, contacts: [], report: report,
            telemetry: .init(backend: .nativeMetal, commandBufferCount: 1, encoderCount: 2, gpuMilliseconds: timing.gpuMilliseconds),
            profile: profile, isComplete: false)
        // Synchroniczna publikacja dopiero po pomyślnym wykonaniu i readbacku.
        state.publish()
        persistentState = state
        lastSnapshot = snapshot
        publishedFrame = frame
        return frame
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }
}
