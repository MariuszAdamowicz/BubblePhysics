public enum ReferenceSimulationBackend: String, Equatable, Sendable, CaseIterable {
    case cpu
    case metal
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

    /// Eligibility for device comparison, never an acceptance verdict. Physical
    /// device, Release, timing budget and CPU quality still need verification.
    public var isGPUAcceptanceMeasurementEligible: Bool {
        backend == .metal && measuredSteps > 0 && cpuFrameCount == 0
            && metalFrameCount == warmupSteps + measuredSteps
            && fallbackCount == 0 && !hasNonFiniteState
    }
}
