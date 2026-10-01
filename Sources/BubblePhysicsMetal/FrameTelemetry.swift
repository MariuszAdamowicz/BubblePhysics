import Foundation
import BubblePhysics

public struct RadialFrameMetrics: Equatable, Sendable {
    public let gpuFrameMilliseconds: Double
    public let sensorCount: Int
    public let minimumRadialLength: Float
    public let meanRadialLength: Float
    public let maximumRadialLength: Float
    public let bodySpeed: Float
    public let angularSpeed: Float
    public let maximumPressure: Float
    public let kineticEnergy: Float
    public let didOverflow: Bool
    public let didEncounterNonFinite: Bool

    public init(
        state: RadialBubbleState,
        frame: MetalRadialFrameResources? = nil,
        gpuFrameMilliseconds: Double = 0
    ) {
        let lengths = state.sensors.map(\.length)
        let pressures = state.sensors.map(\.pressure)
        let velocity = state.body.linearVelocity
        let linearSpeedSquared = velocity.x * velocity.x + velocity.y * velocity.y
        let finiteScalars = lengths
            + state.sensors.map(\.radialVelocity)
            + pressures
            + [
                state.body.center.x, state.body.center.y,
                velocity.x, velocity.y,
                state.body.angle, state.body.angularVelocity
            ]
        self.gpuFrameMilliseconds = gpuFrameMilliseconds
        sensorCount = lengths.count
        minimumRadialLength = lengths.min() ?? 0
        meanRadialLength = lengths.isEmpty ? 0 : lengths.reduce(0, +) / Float(lengths.count)
        maximumRadialLength = lengths.max() ?? 0
        bodySpeed = sqrt(max(0, linearSpeedSquared))
        angularSpeed = abs(state.body.angularVelocity)
        maximumPressure = pressures.max() ?? 0
        kineticEnergy = 0.5 * state.body.mass * linearSpeedSquared
            + 0.5 * state.body.momentOfInertia
                * state.body.angularVelocity * state.body.angularVelocity
        didOverflow = frame.map {
            $0.contactOverflowBuffer.contents()
                .bindMemory(to: UInt32.self, capacity: 1).pointee != 0
        } ?? false
        didEncounterNonFinite = !gpuFrameMilliseconds.isFinite
            || !finiteScalars.allSatisfy(\.isFinite)
            || !kineticEnergy.isFinite
    }

    private init() {
        gpuFrameMilliseconds = 0; sensorCount = 0
        minimumRadialLength = 0; meanRadialLength = 0; maximumRadialLength = 0
        bodySpeed = 0; angularSpeed = 0; maximumPressure = 0; kineticEnergy = 0
        didOverflow = false; didEncounterNonFinite = false
    }

    public static let zero = RadialFrameMetrics()
}

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
    public let radial: RadialFrameMetrics

    public init(fps: Double, p50Milliseconds: Double, p95Milliseconds: Double, sampleCount: Int, failure: MetalSessionFailure?, timings: FrameTelemetryTimings = .zero, counters: FrameTelemetryCounters = .zero, radial: RadialFrameMetrics = .zero) {
        self.fps = fps; self.p50Milliseconds = p50Milliseconds; self.p95Milliseconds = p95Milliseconds
        self.sampleCount = sampleCount; self.failure = failure
        contourMilliseconds = timings.contourMilliseconds; remeshingMilliseconds = timings.remeshingMilliseconds; renderingMilliseconds = timings.renderingMilliseconds
        particleCount = counters.particleCount; segmentCount = counters.segmentCount; candidatePairCount = counters.candidatePairCount
        contactCount = counters.contactCount; remeshOperationCount = counters.remeshOperationCount
        didOverflow = counters.didOverflow; didEncounterNonFinite = counters.didEncounterNonFinite
        self.radial = radial
    }
}

public struct FrameTelemetry: Sendable {
    private let windowSize: Int
    private var samples: [Double] = []
    private var failure: MetalSessionFailure?
    private var timings: FrameTelemetryTimings = .zero
    private var counters: FrameTelemetryCounters = .zero
    private var radial: RadialFrameMetrics = .zero

    public init(windowSize: Int = 120) { self.windowSize = max(1, windowSize) }

    public mutating func record(milliseconds: Double) {
        record(milliseconds: milliseconds, timings: timings, counters: counters)
    }

    public mutating func record(milliseconds: Double, timings: FrameTelemetryTimings, counters: FrameTelemetryCounters, radial: RadialFrameMetrics = .zero) {
        guard failure == nil, milliseconds.isFinite, milliseconds >= 0 else { return }
        guard [timings.contourMilliseconds, timings.remeshingMilliseconds, timings.renderingMilliseconds].allSatisfy({ $0.isFinite && $0 >= 0 }) else { return }
        samples.append(milliseconds)
        if samples.count > windowSize { samples.removeFirst(samples.count - windowSize) }
        self.timings = timings; self.counters = counters; self.radial = radial
    }

    public mutating func reset() { samples.removeAll(keepingCapacity: true); failure = nil; timings = .zero; counters = .zero; radial = .zero }
    public mutating func fail(_ failure: MetalSessionFailure) { self.failure = failure }

    public var snapshot: FrameTelemetrySnapshot {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            return sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
        }
        let p50 = percentile(0.5)
        return .init(fps: p50 > 0 ? 1_000 / p50 : 0, p50Milliseconds: p50, p95Milliseconds: percentile(0.95), sampleCount: samples.count, failure: failure, timings: timings, counters: counters, radial: radial)
    }
}
