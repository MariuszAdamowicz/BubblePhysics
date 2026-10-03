public struct ReferenceWorldStepReport: Sendable, Equatable {
    public var solver: ReferenceSolverReport
    public var candidatePairCount: Int
    public var generatedContactCount: Int
    public var persistentContactCount: Int
    public var toiTestCount: Int
    public var sideCorrectionCount: Int
    public var ccdBudgetExhaustionCount: Int
    public var centerGuardCount: Int
    public var generatedContourPointCount: Int
    public var predictionMilliseconds: Double
    public var broadPhaseMilliseconds: Double
    public var contactMilliseconds: Double
    public var solverMilliseconds: Double
    public var totalMilliseconds: Double
    public var hasNonFiniteState: Bool

    public init(
        solver: ReferenceSolverReport,
        candidatePairCount: Int,
        generatedContactCount: Int,
        persistentContactCount: Int,
        toiTestCount: Int,
        sideCorrectionCount: Int,
        ccdBudgetExhaustionCount: Int,
        centerGuardCount: Int = 0,
        generatedContourPointCount: Int = 0,
        predictionMilliseconds: Double,
        broadPhaseMilliseconds: Double,
        contactMilliseconds: Double,
        solverMilliseconds: Double,
        totalMilliseconds: Double,
        hasNonFiniteState: Bool
    ) {
        self.solver = solver
        self.candidatePairCount = candidatePairCount
        self.generatedContactCount = generatedContactCount
        self.persistentContactCount = persistentContactCount
        self.toiTestCount = toiTestCount
        self.sideCorrectionCount = sideCorrectionCount
        self.ccdBudgetExhaustionCount = ccdBudgetExhaustionCount
        self.centerGuardCount = centerGuardCount
        self.generatedContourPointCount = generatedContourPointCount
        self.predictionMilliseconds = predictionMilliseconds
        self.broadPhaseMilliseconds = broadPhaseMilliseconds
        self.contactMilliseconds = contactMilliseconds
        self.solverMilliseconds = solverMilliseconds
        self.totalMilliseconds = totalMilliseconds
        self.hasNonFiniteState = hasNonFiniteState
    }
}
