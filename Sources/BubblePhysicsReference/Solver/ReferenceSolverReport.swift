public struct ReferenceSolverReport: Sendable, Equatable {
    public var iterations: Int
    public var maximumPenetration: Float
    public var converged: Bool
    public var didReachIterationLimit: Bool
    public var positionCorrectionCount: Int
    public var deformationCount: Int
    public var pcgIterationCount: Int
    public var initialResidualNorm: Float
    public var finalResidualNorm: Float
    public var maximumRelativeDeformation: Float
    public var lineSearchFailureCount: Int
    public var hasNonFiniteState: Bool
    public var contactComponentCount: Int
    public var unconvergedContactComponentCount: Int
    public var maximumComponentResidualNorm: Float

    public var newtonIterationCount: Int { iterations }
    public var maximumCompression: Float { maximumPenetration }
    public var didReachNewtonLimit: Bool { didReachIterationLimit }

    public init(
        iterations: Int,
        maximumPenetration: Float,
        converged: Bool,
        didReachIterationLimit: Bool,
        positionCorrectionCount: Int,
        deformationCount: Int,
        pcgIterationCount: Int = 0,
        initialResidualNorm: Float = 0,
        finalResidualNorm: Float = 0,
        maximumRelativeDeformation: Float = 0,
        lineSearchFailureCount: Int = 0,
        hasNonFiniteState: Bool = false,
        contactComponentCount: Int = 0,
        unconvergedContactComponentCount: Int = 0,
        maximumComponentResidualNorm: Float = 0
    ) {
        self.iterations = iterations
        self.maximumPenetration = maximumPenetration
        self.converged = converged
        self.didReachIterationLimit = didReachIterationLimit
        self.positionCorrectionCount = positionCorrectionCount
        self.deformationCount = deformationCount
        self.pcgIterationCount = pcgIterationCount
        self.initialResidualNorm = initialResidualNorm
        self.finalResidualNorm = finalResidualNorm
        self.maximumRelativeDeformation = maximumRelativeDeformation
        self.lineSearchFailureCount = lineSearchFailureCount
        self.hasNonFiniteState = hasNonFiniteState
        self.contactComponentCount = contactComponentCount
        self.unconvergedContactComponentCount = unconvergedContactComponentCount
        self.maximumComponentResidualNorm = maximumComponentResidualNorm
    }
}
