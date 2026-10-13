import Foundation
import Metal
import BubblePhysicsReference

enum NativeMetalSolverError: Error {
    case resourceUnavailable, allocationFailed, commandSetupFailed, commandFailed(String), invalidSnapshot, capacityOverflow
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
    var contactCache: MTLBuffer { publishedIsPing ? cachePing : cachePong }
    var workingCache: MTLBuffer { publishedIsPing ? cachePong : cachePing }
    var publishedCacheCount = 0
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

    init(device: MTLDevice, bubbleCount: Int, segmentCount: Int, candidateCapacity: Int? = nil) throws {
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
        let (rowStride, strideOverflow) = bubbleCapacity.addingReportingOverflow(segmentCapacity)
        let (rowCapacity, rowOverflow) = bubbleCapacity.multipliedReportingOverflow(by: rowStride)
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
        dispatchStatistics = try buffer("dispatchStatistics", 2, MemoryLayout<SIMD4<UInt32>>.stride)
        scratch = try buffer("scratch", bubbleCapacity, MemoryLayout<SIMD4<Float>>.stride)
        renderPackets = try buffer("renderPackets", bubbleCapacity, MemoryLayout<NativeMetalRenderPacket>.stride)
        control = try buffer("control", 1, MemoryLayout<NativeMetalControl>.stride)
    }

    func publish() { publishedIsPing.toggle() }
}

/// Trwały stan GPU, predykcja i kontakty. Klatka jest niepełna,
/// dopóki kolejne zadania nie dodadzą solvera i walidacji publikacji.
@MainActor
final class NativeMetalSolver: NativeMetalFrameExecuting {
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let predict: MTLComputePipelineState
    private let pipelines: [String: MTLComputePipelineState]
    private let configuration: NativeMetalConfiguration
    private let candidateCapacity: Int?
    private let collectDispatchStatistics: Bool
    private let commandExecutor: any NativeMetalCommandExecuting
    private var inFlight = false
    private var lastSnapshot: NativeMetalSnapshot?
    private var frameNumber: UInt32 = 0
    private(set) var cachedContacts: [NativeContactCacheRecord] = []
    private(set) var candidateKeys: [NativeContactKey] = []
    private(set) var persistentState: NativeMetalPersistentState?
    private(set) var publishedFrame: NativeMetalWorldFrame?

    init(device: MTLDevice, commandExecutor: (any NativeMetalCommandExecuting)? = nil,
         configuration: NativeMetalConfiguration = .default, candidateCapacity: Int? = nil,
         collectDispatchStatistics: Bool = false) throws {
        self.device = device
        self.configuration = configuration.sanitized
        self.candidateCapacity = candidateCapacity
        self.collectDispatchStatistics = collectDispatchStatistics
        self.commandExecutor = commandExecutor ?? NativeMetalCommandExecutor()
        guard let queue = device.makeCommandQueue(),
              let url = Bundle.module.url(forResource: "NativeGeometryKernels", withExtension: "metal-source")
        else { throw NativeMetalSolverError.resourceUnavailable }
        self.queue = queue
        guard let cacheURL = Bundle.module.url(forResource: "NativeXPBDKernels", withExtension: "metal-source")
        else { throw NativeMetalSolverError.resourceUnavailable }
        let source = try String(contentsOf: url, encoding: .utf8) + "\n" + String(contentsOf: cacheURL, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "nativePredict")
        else { throw NativeMetalSolverError.resourceUnavailable }
        predict = try device.makeComputePipelineState(function: function)
        var stages: [String: MTLComputePipelineState] = [:]
        for name in ["nativePrepareGrid", "nativeBuildGrid", "nativeSortGrid", "nativeEmitCandidates",
                     "nativePrepareCandidateCounts", "nativeCompactCandidates", "nativeBuildContacts",
                     "nativePrepareContactFlags", "nativeCompactActiveContacts", "nativeMatchContactCache",
                     "nativeRetainContactCache", "nativeCompactContactCache", "nativeScanBlocks",
                     "nativeAddScanBlockOffsets", "nativeFinishScan"] {
            guard let function = library.makeFunction(name: name) else { throw NativeMetalSolverError.resourceUnavailable }
            stages[name] = try device.makeComputePipelineState(function: function)
        }
        pipelines = stages
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
        guard frameNumber < UInt32.max else { throw NativeMetalSolverError.invalidSnapshot }
        let nextFrame = frameNumber + 1
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
                segmentCount: max(segmentCount, persistentState?.segmentCapacity ?? 0), candidateCapacity: candidateCapacity)
            if let previous = persistentState {
                // Nie ma klatki w locie. Kopiujemy ukończony stan do nowych shared buffers.
                memcpy(state.publishedBubbles.contents(), previous.publishedBubbles.contents(),
                       min(state.publishedBubbles.length, previous.publishedBubbles.length))
                memcpy(state.contactCache.contents(), previous.contactCache.contents(),
                       min(state.contactCache.length, previous.contactCache.length))
                state.publishedCacheCount = previous.publishedCacheCount
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
        // Wyłącznie zmiany wejścia gry mogą oznaczać teleport; normalna predykcja nie resetuje cache.
        let previousBubbles = Dictionary(uniqueKeysWithValues: (lastSnapshot?.sourceBubbles ?? []).map { ($0.id, $0) })
        let previousSegments = Dictionary(uniqueKeysWithValues: (lastSnapshot?.sourceSegments ?? []).map { ($0.id, $0) })
        var invalidationRecords: [SIMD2<Int64>] = []
        for bubble in snapshot.sourceBubbles {
            if let previous = previousBubbles[bubble.id],
               (bubble.center - previous.center).length > configuration.teleportDistanceMultiplier * bubble.targetRadius {
                invalidationRecords.append(SIMD2(Int64(bubble.id.rawValue), 0))
            }
        }
        for segment in snapshot.sourceSegments {
            if let previous = previousSegments[segment.id], previous != segment {
                invalidationRecords.append(SIMD2(Int64(segment.id.rawValue), 1))
            }
        }
        for (index, value) in invalidationRecords.enumerated() {
            state.invalidations.contents().advanced(by: index * MemoryLayout<SIMD2<Int64>>.stride).storeBytes(of: value, as: SIMD2<Int64>.self)
        }
        let contactParameters = NativeMetalContactControl(
            limits: SIMD4(nextFrame, UInt32(clamping: configuration.cacheExpiryFrames), UInt32(state.contactCapacity), UInt32(state.publishedCacheCount)),
            counts: .zero, cache: SIMD4(0, 0, UInt32(invalidationRecords.count), UInt32(count + segmentCount)),
            thresholds: SIMD4(configuration.teleportDistanceMultiplier, configuration.ccdVelocityMultiplier, snapshot.configuration.contactTolerance, 0))
        state.contactControl.contents().storeBytes(of: contactParameters, as: NativeMetalContactControl.self)
        memset(state.dispatchStatistics.contents(), 0, state.dispatchStatistics.length)
        state.dispatchStatistics.contents().advanced(by: 16).storeBytes(of: SIMD4<UInt32>(collectDispatchStatistics ? 1 : 0, 0, 0, 0), as: SIMD4<UInt32>.self)

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
                encoder.dispatchThreadgroups(.init(width: (lengths[level] + 255) / 256, height: 1, depth: 1),
                    threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
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
                    encoder.dispatchThreads(.init(width: lengths[level], height: 1, depth: 1),
                        threadsPerThreadgroup: .init(width: 256, height: 1, depth: 1))
                }
            }
            encoder.memoryBarrier(scope: .buffers)
            encoder.setComputePipelineState(pipelines["nativeFinishScan"]!)
            for (i, b) in [state.scanOffsets, state.control, state.contactControl].enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
            var parameters = SIMD2(mode, UInt32(0))
            encoder.setBytes(&parameters, length: MemoryLayout<SIMD2<UInt32>>.stride, index: 3)
            encoder.dispatchThreads(.init(width: 1, height: 1, depth: 1), threadsPerThreadgroup: .init(width: 1, height: 1, depth: 1))
        }
        dispatch("nativePrepareGrid", buffers: [state.workingBubbles, state.control, state.contactControl], threads: 1)
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
            state.grid, state.workingSegments, state.candidateRows, state.candidateRowCounts], threads: count)
        dispatch("nativePrepareCandidateCounts", buffers: [state.control, state.candidateRowCounts, state.scanValues], threads: count * 2)
        scan(mode: 0, maximum: max(1, count * 2))
        dispatch("nativeCompactCandidates", buffers: [state.control, state.contactControl, state.candidateRows,
            state.candidateRowCounts, state.candidates, state.scanOffsets, state.dispatchStatistics], threads: count * (count + segmentCount))
        dispatch("nativeBuildContacts", buffers: [state.workingBubbles, state.workingSegments, state.contactControl,
            state.candidates, state.contacts], threads: state.contactCapacity)
        dispatch("nativePrepareContactFlags", buffers: [state.contacts, state.contactControl, state.scanValues], threads: state.contactCapacity)
        scan(mode: 1, maximum: state.contactCapacity)
        dispatch("nativeCompactActiveContacts", buffers: [state.contacts, state.activeContacts, state.contactControl, state.scanOffsets], threads: state.contactCapacity)
        dispatch("nativeMatchContactCache", buffers: [state.contactCache, state.activeContacts, state.mergedCache,
            state.contactControl, state.invalidations, state.workingBubbles, state.workingSegments, state.control,
            state.scanValues, state.dispatchStatistics], threads: state.contactCapacity)
        dispatch("nativeRetainContactCache", buffers: [state.contactCache, state.activeContacts, state.mergedCache,
            state.contactControl, state.invalidations, state.workingBubbles, state.workingSegments, state.control,
            state.scanValues, state.dispatchStatistics], threads: state.publishedCacheCount)
        scan(mode: 2, maximum: state.contactCapacity + state.publishedCacheCount)
        dispatch("nativeCompactContactCache", buffers: [state.mergedCache, state.workingCache, state.contactControl,
            state.scanValues, state.scanOffsets, state.dispatchStatistics], threads: state.contactCapacity + state.publishedCacheCount)
        encoder.endEncoding()
        let encodingEnd = DispatchTime.now().uptimeNanoseconds
        // Jedyny await/commit: wszystkie etapy zostały już zakodowane.
        let timing = try await commandExecutor.complete(command)
        let waitingEnd = DispatchTime.now().uptimeNanoseconds
        let contactResult = state.contactControl.contents().load(as: NativeMetalContactControl.self)
        guard contactResult.counts.w == 0 else { throw NativeMetalSolverError.capacityOverflow }
        let cacheRecords = state.workingCache.contents().bindMemory(to: NativeContactCacheRecord.self, capacity: state.contactCapacity)
        let completedCache = Array(UnsafeBufferPointer(start: cacheRecords, count: Int(contactResult.counts.z)))
        let candidateRecords = state.candidates.contents().bindMemory(to: NativeMetalCandidate.self, capacity: state.contactCapacity)
        let completedCandidates = Array(UnsafeBufferPointer(start: candidateRecords, count: Int(contactResult.counts.x))).map(\.key)
        let contacts = completedCache.filter { $0.lastSeenFrame == nextFrame }.map { record in
            // ID API referencyjnego jest skrótem; cache GPU zawsze używa pełnego klucza.
            var hash: UInt64 = 14695981039346656037
            for value in [UInt64(record.key.kind), UInt64(bitPattern: record.key.first), UInt64(bitPattern: record.key.second)] {
                hash = (hash ^ value) &* 1099511628211
            }
            return ReferenceContact(id: .init(rawValue: hash), kind: record.key.kind == 0 ? .bubbleBubble : .bubbleSegment,
                bubbleA: .init(rawValue: Int(record.key.first)),
                bubbleB: record.key.kind == 0 ? .init(rawValue: Int(record.key.second)) : nil,
                segment: record.key.kind == 1 ? .init(rawValue: Int(record.key.second)) : nil,
                normal: .init(x: record.geometry.x, y: record.geometry.y), pointQ: .init(x: record.geometry.z, y: record.geometry.w),
                penetration: record.response.y, allowedSide: record.response.z == 0 ? nil : record.response.z,
                accumulatedCompression: record.lambda, age: Int(record.age))
        }
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
        profile.stageGPUMilliseconds = ["frame": timing.gpuMilliseconds]
        if collectDispatchStatistics {
            let counts = state.dispatchStatistics.contents().load(as: SIMD4<UInt32>.self)
            profile.stageGPUWorkItemCounts = ["cacheMatch": Int(counts.x), "cacheRetain": Int(counts.y),
                "cacheCompaction": Int(counts.z), "candidateCompaction": Int(counts.w)]
        }
        let report = ReferenceWorldStepReport(solver: .init(iterations: 0, maximumPenetration: 0, converged: false,
            didReachIterationLimit: false, positionCorrectionCount: 0, deformationCount: 0),
            candidatePairCount: Int(contactResult.counts.x), generatedContactCount: contacts.count,
            persistentContactCount: Int(contactResult.cache.x), toiTestCount: 0,
            sideCorrectionCount: 0, ccdBudgetExhaustionCount: 0, predictionMilliseconds: 0,
            broadPhaseMilliseconds: 0, contactMilliseconds: 0, solverMilliseconds: 0,
            totalMilliseconds: milliseconds(waitingEnd - encodingStart), hasNonFiniteState: false)
        let frame = NativeMetalWorldFrame(bubbles: bubbles, contacts: contacts, report: report,
            telemetry: .init(backend: .nativeMetal, commandBufferCount: 1, encoderCount: 2,
                cacheHitCount: Int(contactResult.cache.x), cacheResetCount: Int(contactResult.cache.y),
                contactCount: contacts.count, gpuMilliseconds: timing.gpuMilliseconds),
            profile: profile, isComplete: false)
        // Synchroniczna publikacja dopiero po pomyślnym wykonaniu i readbacku.
        state.publish()
        state.publishedCacheCount = completedCache.count
        cachedContacts = completedCache
        candidateKeys = completedCandidates
        frameNumber = nextFrame
        persistentState = state
        lastSnapshot = snapshot
        publishedFrame = frame
        return frame
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double { Double(nanoseconds) / 1_000_000 }
}
