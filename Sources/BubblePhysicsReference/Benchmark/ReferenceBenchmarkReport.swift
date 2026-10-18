public enum ReferenceSimulationBackend: String, Equatable, Sendable, CaseIterable {
    case cpu
    case metal
    case nativeMetal = "native-metal"

    public var isGPU: Bool { self != .cpu }
}

/// Neutral telemetry from a successfully published GPU-native frame.
public struct ReferenceBenchmarkNativeFrameTelemetry: Sendable, Equatable {
    public var cacheHits: Int
    public var cacheResets: Int
    public var solverIterations: Int
    public var ccdCandidates: Int

    public init(cacheHits: Int, cacheResets: Int, solverIterations: Int, ccdCandidates: Int) {
        self.cacheHits = cacheHits
        self.cacheResets = cacheResets
        self.solverIterations = solverIterations
        self.ccdCandidates = ccdCandidates
    }
}

/// Neutral evidence and verdict measured outside the timed native frame batch.
/// Optional values remain absent when any contributing frame used CPU fallback.
public struct ReferenceBenchmarkNativeQualityReport: Sendable, Equatable {
    public var cpuBaselineMeasuredFrames = 0
    public var cpuPenetrationP95: Double?
    public var cpuPenetrationMaximum: Double?
    public var restSettleFrames = 0
    public var restMeasuredFrames = 0
    public var maximumRestDisplacementRadiusFraction: Double?
    public var releasedContourFrames = 0
    public var loadedContourMeanRadiusErrorFraction: Double?
    public var releasedContourMeanRadiusErrorFraction: Double?
    public var contourOscillationGrows: Bool?
    public var repeatMeasuredFrames = 0
    public var publishedStateHash: UInt64?
    public var repeatedPublishedStateHash: UInt64?
    public var violations: [String] = []

    public init() {}
}

public struct ReferenceTimingSummary: Sendable, Equatable {
    public var p50Milliseconds: Double
    public var p95Milliseconds: Double
    public var maximumMilliseconds: Double

    public init(p50Milliseconds: Double, p95Milliseconds: Double, maximumMilliseconds: Double = 0) {
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }

    public init(values: [Double]) {
        let ordered = values.filter(\.isFinite).sorted()
        guard !ordered.isEmpty else {
            self.init(p50Milliseconds: 0, p95Milliseconds: 0, maximumMilliseconds: 0)
            return
        }
        self.init(
            p50Milliseconds: Self.percentile(ordered, fraction: 0.50),
            p95Milliseconds: Self.percentile(ordered, fraction: 0.95),
            maximumMilliseconds: ordered.last ?? 0
        )
    }

    private static func percentile(_ ordered: [Double], fraction: Double) -> Double {
        let index = max(0, min(ordered.count - 1, Int((Double(ordered.count) * fraction).rounded(.up)) - 1))
        return ordered[index]
    }
}

public struct ReferenceScalarSummary: Sendable, Equatable {
    public var p50: Double
    public var p95: Double
    public var maximum: Double

    public init(values: [Double]) {
        let timing = ReferenceTimingSummary(values: values)
        p50 = timing.p50Milliseconds
        p95 = timing.p95Milliseconds
        maximum = timing.maximumMilliseconds
    }
}

/// Reference-owned values keep benchmark reporting independent of Metal APIs.
public struct ReferenceBenchmarkGPUFailureSummary: Sendable, Equatable {
    public var stage: String
    public var scenarioStep: Int
    public var reason: String
    public var classification: String
    public var isFatal: Bool

    public init(stage: String, scenarioStep: Int, reason: String, classification: String, isFatal: Bool) {
        self.stage = stage
        self.scenarioStep = scenarioStep
        self.reason = reason
        self.classification = classification
        self.isFatal = isFatal
    }
}

public struct ReferenceBenchmarkGPUFrameTelemetry: Sendable, Equatable {
    /// Sum of completed command buffers of a successfully published Metal frame.
    /// Absent on CPU/fallback, including attempts failing after partial GPU work.
    public var completedCommandBuffersMilliseconds: Double?
    public var failure: ReferenceBenchmarkGPUFailureSummary?
    public var solveCallCount: Int?
    public var tentativeSolveCallCount: Int?
    public var contactCount: Int?
    public var ccdGroupCount: Int?
    public var profile: ReferenceBenchmarkGPUFrameProfile?
    public var native: ReferenceBenchmarkNativeFrameTelemetry?

    public init(completedCommandBuffersMilliseconds: Double? = nil,
                failure: ReferenceBenchmarkGPUFailureSummary? = nil,
                solveCallCount: Int? = nil, tentativeSolveCallCount: Int? = nil,
                contactCount: Int? = nil, ccdGroupCount: Int? = nil,
                profile: ReferenceBenchmarkGPUFrameProfile? = nil,
                native: ReferenceBenchmarkNativeFrameTelemetry? = nil) {
        self.completedCommandBuffersMilliseconds = completedCommandBuffersMilliseconds
        self.failure = failure
        self.solveCallCount = solveCallCount
        self.tentativeSolveCallCount = tentativeSolveCallCount
        self.contactCount = contactCount
        self.ccdGroupCount = ccdGroupCount
        self.profile = profile
        self.native = native
    }
}

public struct ReferenceBenchmarkReport: Sendable, Equatable {
    public var benchmarkVersion: String = "legacy-microbenchmark-v1"
    public var scene: ReferenceConvergenceScene? = nil
    public var seed: UInt64 = 0
    public var newtonIterationLimit: Int = 0
    public var pcgIterationLimit: Int = 0
    public var timeStep: Float = 0
    public var stressTolerance: Float = 0
    public var scenarioName: String
    public var broadPhase: ReferenceBroadPhaseSelection
    public var warmupSteps: Int
    public var measuredSteps: Int
    public var frame: ReferenceTimingSummary
    public var prediction: ReferenceTimingSummary
    public var broadPhaseTiming: ReferenceTimingSummary
    public var contacts: ReferenceTimingSummary
    public var solver: ReferenceTimingSummary
    public var maximumCandidatePairs: Int
    public var maximumGeneratedContacts: Int
    public var maximumPersistentContacts: Int
    public var maximumSolverIterations: Int
    public var maximumTOITests: Int
    public var maximumPenetration: Float
    public var sideCorrectionCount: Int
    public var ccdBudgetExhaustionCount: Int
    public var solverIterationLimitCount: Int
    public var hasNonFiniteState: Bool
    public var fullFrame: ReferenceTimingSummary = .init(p50Milliseconds: 0, p95Milliseconds: 0)
    public var contour: ReferenceTimingSummary = .init(p50Milliseconds: 0, p95Milliseconds: 0)
    public var renderPreparation: ReferenceTimingSummary = .init(p50Milliseconds: 0, p95Milliseconds: 0)
    public var penetration: ReferenceScalarSummary = .init(values: [])
    public var initialResidual: ReferenceScalarSummary = .init(values: [])
    public var finalResidual: ReferenceScalarSummary = .init(values: [])
    public var maximumContactComponents: Int = 0
    public var maximumUnconvergedContactComponents: Int = 0
    public var maximumComponentResidualNorm: Float = 0
    public var maximumPCGIterations: Int = 0
    public var maximumConsecutiveContainmentFrames: Int = 0
    public var maximumContourPointCount: Int = 0
    public var backend: ReferenceSimulationBackend = .cpu
    // Counts include warmup: a fallback there changes the measured trajectory.
    public var cpuFrameCount: Int = 0
    public var metalFrameCount: Int = 0
    public var fallbackCount: Int = 0
    public var warmupFallbackCount: Int = 0
    public var fallbackReasons: [String: Int] = [:]
    // These summaries contain measured frames only; absent telemetry is not zero.
    public var completedMetalTiming: ReferenceTimingSummary = .init(values: [])
    public var completedMetalSampleCount: Int = 0
    public var gpuProfileSampleCount: Int = 0
    public var gpuProfileCommandBuffers: ReferenceTimingSummary = .init(values: [])
    public var gpuProfileEncoders: ReferenceTimingSummary = .init(values: [])
    public var gpuProfileStages: [String: ReferenceTimingSummary] = [:]
    public var gpuProfileStageSampleCounts: [String: Int] = [:]
    public var gpuProfileHostEncoding: ReferenceTimingSummary = .init(values: [])
    public var gpuProfileHostWaiting: ReferenceTimingSummary = .init(values: [])
    public var gpuProfileHostReadback: ReferenceTimingSummary = .init(values: [])
    public var cpuFallbackFullFrameTiming: ReferenceTimingSummary = .init(values: [])
    public var cpuFallbackSampleCount: Int = 0
    public var maximumGPUSolveCalls: Int? = nil
    public var maximumGPUTentativeSolveCalls: Int? = nil
    public var maximumGPUContacts: Int? = nil
    public var maximumGPUCCDGroups: Int? = nil
    // Failure retention includes warmup and survives latched CPU frames.
    public var firstGPUFailure: ReferenceBenchmarkGPUFailureSummary? = nil
    public var firstFatalGPUFailure: ReferenceBenchmarkGPUFailureSummary? = nil
    // Native counters include completed measured GPU frames only.
    public var nativeTelemetrySampleCount: Int = 0
    public var nativeCacheHits: Int? = nil
    public var nativeCacheResets: Int? = nil
    public var maximumNativeSolverIterations: Int? = nil
    public var nativeCCDCandidates: Int? = nil
    public var nativeQuality: ReferenceBenchmarkNativeQualityReport? = nil

    /// Eligibility for device comparison, never an acceptance verdict. Physical
    /// device, Release, timing budget and CPU quality still need verification.
    public var isGPUAcceptanceMeasurementEligible: Bool {
        backend.isGPU && measuredSteps > 0 && cpuFrameCount == 0
            && metalFrameCount == warmupSteps + measuredSteps
            && completedMetalSampleCount == measuredSteps
            && fallbackCount == 0 && firstFatalGPUFailure == nil && !hasNonFiniteState
    }
}
