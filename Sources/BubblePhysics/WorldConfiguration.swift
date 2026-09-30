public struct WorldConfiguration: Equatable, Sendable {
    public let fixedTimeStep: Float
    public let solverIterations: Int
    public let maxBoundarySegmentLength: Float
    public let linearDamping: Float

    public init(
        fixedTimeStep: Float,
        solverIterations: Int,
        maxBoundarySegmentLength: Float,
        linearDamping: Float
    ) {
        self.fixedTimeStep = fixedTimeStep
        self.solverIterations = solverIterations
        self.maxBoundarySegmentLength = maxBoundarySegmentLength
        self.linearDamping = linearDamping
    }

    public static let `default` = WorldConfiguration(
        fixedTimeStep: 1.0 / 60.0,
        solverIterations: 8,
        maxBoundarySegmentLength: 8,
        linearDamping: 0.05
    )
}
