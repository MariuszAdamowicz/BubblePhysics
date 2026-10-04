import Metal

enum ReferenceMetalAllocation: CaseIterable, Hashable {
    case centers, velocities, contacts, components

    var stride: Int {
        switch self {
        case .centers, .velocities: MemoryLayout<SIMD2<Float>>.stride
        case .contacts: MemoryLayout<ReferenceMetalContact>.stride
        case .components: MemoryLayout<ReferenceMetalComponent>.stride
        }
    }
}

struct ReferenceMetalFrameRequirements {
    let snapshot: ReferenceMetalSnapshot
    let capacities: [ReferenceMetalAllocation: Int]

    init(snapshot: ReferenceMetalSnapshot, capacities: [ReferenceMetalAllocation: Int] = [:]) {
        self.snapshot = snapshot
        var counts = capacities
        counts[.centers] = max(counts[.centers] ?? 0, snapshot.centers.count)
        counts[.velocities] = max(counts[.velocities] ?? 0, snapshot.velocities.count)
        counts[.contacts] = max(counts[.contacts] ?? 0, snapshot.contacts.count)
        self.capacities = counts
    }
}

struct ReferenceMetalFrameAttempt {
    let snapshot: ReferenceMetalSnapshot
    let capacities: [ReferenceMetalAllocation: Int]
    let buffers: [ReferenceMetalAllocation: MTLBuffer]
    let inputBuffers: [String: MTLBuffer]
}

struct ReferenceMetalAttemptResult {
    let output: ReferenceMetalFrameOutput
    let telemetry: ReferenceMetalFrameTelemetry
    /// Exhausted allocations and their required element counts, read after GPU completion.
    let exhausted: [ReferenceMetalAllocation: Int]

    init(output: ReferenceMetalFrameOutput, telemetry: ReferenceMetalFrameTelemetry,
         exhausted: [ReferenceMetalAllocation: Int] = [:]) {
        self.output = output
        self.telemetry = telemetry
        self.exhausted = exhausted
    }
}

enum ReferenceMetalCapacityError: Error {
    case allocationFailed, capacityOverflow, invalidOverflowReport, frameInFlight
}

/// Serial frame owner. The encoder must await command completion and report
/// overflow before returning; publication is exclusively owned by this manager.
final class ReferenceMetalCapacityManager {
    private let device: MTLDevice
    private var capacities: [ReferenceMetalAllocation: Int] = [:]
    private var buffers: [ReferenceMetalAllocation: MTLBuffer] = [:]
    private var inputBuffers: [String: MTLBuffer] = [:]
    private var frameInFlight = false
    private(set) var publishedOutput: ReferenceMetalFrameOutput?

    init(device: MTLDevice) { self.device = device }

    func retryingFrame(
        requirements: ReferenceMetalFrameRequirements,
        encode: (ReferenceMetalFrameAttempt) async throws -> ReferenceMetalAttemptResult
    ) async throws -> ReferenceMetalFrameTelemetry {
        guard !frameInFlight else { throw ReferenceMetalCapacityError.frameInFlight }
        frameInFlight = true
        defer { frameInFlight = false }
        for allocation in ReferenceMetalAllocation.allCases {
            try ensure(allocation, count: requirements.capacities[allocation] ?? 0)
        }
        let inputs = try upload(requirements.snapshot)
        var didOverflow = false
        while true {
            try Task.checkCancellation()
            // Restore input in the same allocations even if an encoder wrote to it.
            restore(requirements.snapshot, into: inputs)
            for buffer in buffers.values { memset(buffer.contents(), 0, buffer.length) }
            let result = try await encode(.init(snapshot: requirements.snapshot, capacities: capacities,
                                                buffers: buffers, inputBuffers: inputs))
            if !result.exhausted.isEmpty {
                didOverflow = true
                for (allocation, required) in result.exhausted {
                    guard required > (capacities[allocation] ?? 0) else {
                        throw ReferenceMetalCapacityError.invalidOverflowReport
                    }
                    try ensure(allocation, count: required)
                }
                continue // Discard every output and telemetry value from this attempt.
            }
            guard !result.telemetry.didOverflow else { throw ReferenceMetalCapacityError.invalidOverflowReport }
            try Task.checkCancellation()
            publishedOutput = result.output
            let telemetry = result.telemetry
            return .init(backend: telemetry.backend, frameMilliseconds: telemetry.frameMilliseconds,
                         gpuMilliseconds: telemetry.gpuMilliseconds, finalResidual: telemetry.finalResidual,
                         newtonIterations: telemetry.newtonIterations, pcgIterations: telemetry.pcgIterations,
                         didOverflow: didOverflow, didEncounterNonFinite: telemetry.didEncounterNonFinite,
                         fallbackReason: telemetry.fallbackReason)
        }
    }

    private func ensure(_ allocation: ReferenceMetalAllocation, count: Int) throws {
        guard count >= 0 else { throw ReferenceMetalCapacityError.capacityOverflow }
        if buffers[allocation] != nil, count <= (capacities[allocation] ?? 0) { return }
        let length = try Self.byteLength(count: count, stride: allocation.stride, maximum: device.maxBufferLength)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
            throw ReferenceMetalCapacityError.allocationFailed
        }
        buffers[allocation] = buffer
        capacities[allocation] = count
    }

    static func byteLength(count: Int, stride: Int, maximum: Int) throws -> Int {
        guard count >= 0, stride > 0 else { throw ReferenceMetalCapacityError.capacityOverflow }
        let (length, overflow) = count.multipliedReportingOverflow(by: stride)
        guard !overflow else { throw ReferenceMetalCapacityError.capacityOverflow }
        guard max(16, length) <= maximum else { throw ReferenceMetalCapacityError.allocationFailed }
        return max(16, length)
    }

    private func upload(_ snapshot: ReferenceMetalSnapshot) throws -> [String: MTLBuffer] {
        func buffer<T>(_ values: [T], name: String) throws -> MTLBuffer {
            let length = try Self.byteLength(count: values.count, stride: MemoryLayout<T>.stride, maximum: device.maxBufferLength)
            if let existing = inputBuffers[name], existing.length >= length { return existing }
            guard let result = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw ReferenceMetalCapacityError.allocationFailed
            }
            inputBuffers[name] = result
            return result
        }
        return try ["bubbles": buffer(snapshot.bubbles, name: "bubbles"), "centers": buffer(snapshot.centers, name: "centers"),
                    "previousCenters": buffer(snapshot.previousCenters, name: "previousCenters"), "velocities": buffer(snapshot.velocities, name: "velocities"),
                    "segments": buffer(snapshot.segments, name: "segments"), "contacts": buffer(snapshot.contacts, name: "contacts")]
    }

    private func restore(_ snapshot: ReferenceMetalSnapshot, into buffers: [String: MTLBuffer]) {
        func copy<T>(_ values: [T], to name: String) {
            guard !values.isEmpty, let buffer = buffers[name] else { return }
            _ = values.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
        }
        copy(snapshot.bubbles, to: "bubbles")
        copy(snapshot.centers, to: "centers")
        copy(snapshot.previousCenters, to: "previousCenters")
        copy(snapshot.velocities, to: "velocities")
        copy(snapshot.segments, to: "segments")
        copy(snapshot.contacts, to: "contacts")
    }
}
