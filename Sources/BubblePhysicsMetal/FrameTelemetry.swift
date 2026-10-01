import Foundation

public struct FrameTelemetryTimings: Equatable, Sendable {
    public let contourMilliseconds: Double
    public let remeshingMilliseconds: Double
    public let renderingMilliseconds: Double
    public init(contourMilliseconds: Double, remeshingMilliseconds: Double, renderingMilliseconds: Double) {
        self.contourMilliseconds = contourMilliseconds; self.remeshingMilliseconds = remeshingMilliseconds; self.renderingMilliseconds = renderingMilliseconds
    }
    public static let zero = FrameTelemetryTimings(contourMilliseconds: 0, remeshingMilliseconds: 0, renderingMilliseconds: 0)
}

public struct FrameTelemetryCounters: Equatable, Sendable {
    public let particleCount: Int
    public let segmentCount: Int
    public let candidatePairCount: Int
    public let contactCount: Int
    public let remeshOperationCount: Int
    public let didOverflow: Bool
    public let didEncounterNonFinite: Bool
    public init(particleCount: Int, segmentCount: Int, candidatePairCount: Int, contactCount: Int, remeshOperationCount: Int, didOverflow: Bool, didEncounterNonFinite: Bool) {
        self.particleCount = particleCount; self.segmentCount = segmentCount; self.candidatePairCount = candidatePairCount
        self.contactCount = contactCount; self.remeshOperationCount = remeshOperationCount
        self.didOverflow = didOverflow; self.didEncounterNonFinite = didEncounterNonFinite
    }
    public static let zero = FrameTelemetryCounters(particleCount: 0, segmentCount: 0, candidatePairCount: 0, contactCount: 0, remeshOperationCount: 0, didOverflow: false, didEncounterNonFinite: false)
}

public struct FrameTelemetrySnapshot: Equatable, Sendable {
    public let fps: Double
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let sampleCount: Int
    public let failure: MetalSessionFailure?
    public let contourMilliseconds: Double
    public let remeshingMilliseconds: Double
    public let renderingMilliseconds: Double
    public let particleCount: Int
    public let segmentCount: Int
    public let candidatePairCount: Int
    public let contactCount: Int
    public let remeshOperationCount: Int
    public let didOverflow: Bool
    public let didEncounterNonFinite: Bool

    public init(fps: Double, p50Milliseconds: Double, p95Milliseconds: Double, sampleCount: Int, failure: MetalSessionFailure?, timings: FrameTelemetryTimings = .zero, counters: FrameTelemetryCounters = .zero) {
        self.fps = fps; self.p50Milliseconds = p50Milliseconds; self.p95Milliseconds = p95Milliseconds
        self.sampleCount = sampleCount; self.failure = failure
        contourMilliseconds = timings.contourMilliseconds; remeshingMilliseconds = timings.remeshingMilliseconds; renderingMilliseconds = timings.renderingMilliseconds
        particleCount = counters.particleCount; segmentCount = counters.segmentCount; candidatePairCount = counters.candidatePairCount
        contactCount = counters.contactCount; remeshOperationCount = counters.remeshOperationCount
        didOverflow = counters.didOverflow; didEncounterNonFinite = counters.didEncounterNonFinite
    }
}

public struct FrameTelemetry: Sendable {
    private let windowSize: Int
    private var samples: [Double] = []
    private var failure: MetalSessionFailure?
    private var timings: FrameTelemetryTimings = .zero
    private var counters: FrameTelemetryCounters = .zero

    public init(windowSize: Int = 120) { self.windowSize = max(1, windowSize) }

    public mutating func record(milliseconds: Double) {
        record(milliseconds: milliseconds, timings: timings, counters: counters)
    }

    public mutating func record(milliseconds: Double, timings: FrameTelemetryTimings, counters: FrameTelemetryCounters) {
        guard failure == nil, milliseconds.isFinite, milliseconds >= 0 else { return }
        guard [timings.contourMilliseconds, timings.remeshingMilliseconds, timings.renderingMilliseconds].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        samples.append(milliseconds)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        self.timings = timings; self.counters = counters
    }

    public mutating func reset() { samples.removeAll(keepingCapacity: true); failure = nil; timings = .zero; counters = .zero }
    public mutating func fail(_ failure: MetalSessionFailure) { self.failure = failure }

    public var snapshot: FrameTelemetrySnapshot {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        let p50 = percentile(0.5)
        return .init(fps: p50 > 0 ? 1_000 / p50 : 0, p50Milliseconds: p50, p95Milliseconds: percentile(0.95), sampleCount: samples.count, failure: failure, timings: timings, counters: counters)
    }
}
