public struct ReferenceConfiguration: Sendable, Equatable {
    public var timeStep: Float
    public var solverIterations: Int
    public var contactTolerance: Float
    public var separationTolerance: Float
    public var positionTolerance: Float
    public var baseCompliance: Float
    public var nonlinearStiffening: Float
    public var linearDamping: Float
    public var angularDamping: Float
    public var surfaceFriction: Float
    public var toiIterationBudget: Int
    public var maxContourSegmentLength: Float

    public init(
        timeStep: Float = 1 / 60,
        solverIterations: Int = 12,
        contactTolerance: Float = 0.001,
        separationTolerance: Float = 0.002,
        positionTolerance: Float = 0.0001,
        baseCompliance: Float = 0.00001,
        nonlinearStiffening: Float = 8,
        linearDamping: Float = 1.5,
        angularDamping: Float = 2,
        surfaceFriction: Float = 0.2,
        toiIterationBudget: Int = 8,
        maxContourSegmentLength: Float = 8
    ) {
        self.timeStep = timeStep
        self.solverIterations = solverIterations
        self.contactTolerance = contactTolerance
        self.separationTolerance = separationTolerance
        self.positionTolerance = positionTolerance
        self.baseCompliance = baseCompliance
        self.nonlinearStiffening = nonlinearStiffening
        self.linearDamping = linearDamping
        self.angularDamping = angularDamping
        self.surfaceFriction = surfaceFriction
        self.toiIterationBudget = toiIterationBudget
        self.maxContourSegmentLength = maxContourSegmentLength
    }

    public static let `default` = ReferenceConfiguration()
}
