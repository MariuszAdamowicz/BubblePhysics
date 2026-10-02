public struct ReferenceTimingSummary: Sendable, Equatable {
    public var p50Milliseconds: Double
    public var p95Milliseconds: Double
}

public struct ReferenceBenchmarkReport: Sendable, Equatable {
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
    public var solverIterationLimitCount: Int
    public var hasNonFiniteState: Bool
}
