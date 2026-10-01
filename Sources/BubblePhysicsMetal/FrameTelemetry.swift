import Foundation

public struct FrameTelemetrySnapshot: Equatable, Sendable {
    public let fps: Double
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let sampleCount: Int
    public let failure: MetalSessionFailure?

    public init(fps: Double, p50Milliseconds: Double, p95Milliseconds: Double, sampleCount: Int, failure: MetalSessionFailure?) {
        self.fps = fps; self.p50Milliseconds = p50Milliseconds; self.p95Milliseconds = p95Milliseconds
        self.sampleCount = sampleCount; self.failure = failure
    }
}

public struct FrameTelemetry: Sendable {
    private let windowSize: Int
    private var samples: [Double] = []
    private var failure: MetalSessionFailure?

    public init(windowSize: Int = 120) { self.windowSize = max(1, windowSize) }

    public mutating func record(milliseconds: Double) {
        guard failure == nil, milliseconds.isFinite, milliseconds >= 0 else { return }
        samples.append(milliseconds)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
    }

    public mutating func reset() { samples.removeAll(keepingCapacity: true); failure = nil }
    public mutating func fail(_ failure: MetalSessionFailure) { self.failure = failure }

    public var snapshot: FrameTelemetrySnapshot {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        let p50 = percentile(0.5)
        return .init(fps: p50 > 0 ? 1_000 / p50 : 0, p50Milliseconds: p50, p95Milliseconds: percentile(0.95), sampleCount: samples.count, failure: failure)
    }
}
