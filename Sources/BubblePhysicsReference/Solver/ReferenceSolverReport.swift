public struct ReferenceSolverReport: Sendable, Equatable {
    public var iterations: Int
    public var maximumPenetration: Float
    public var converged: Bool
    public var didReachIterationLimit: Bool
    public var positionCorrectionCount: Int
    public var deformationCount: Int

    public init(
        iterations: Int,
        maximumPenetration: Float,
        converged: Bool,
        didReachIterationLimit: Bool,
        positionCorrectionCount: Int,
        deformationCount: Int
    ) {
        self.iterations = iterations
        self.maximumPenetration = maximumPenetration
        self.converged = converged
        self.didReachIterationLimit = didReachIterationLimit
        self.positionCorrectionCount = positionCorrectionCount
        self.deformationCount = deformationCount
    }
}
