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
    public var deformationRecoveryRate: Float

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
        maxContourSegmentLength: Float = 8,
        deformationRecoveryRate: Float = 12
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
        self.deformationRecoveryRate = deformationRecoveryRate
    }

    public var sanitized: ReferenceConfiguration {
        var value = self
        value.timeStep = value.timeStep.isFinite && value.timeStep > 0 ? value.timeStep : 1 / 60
        value.solverIterations = max(1, value.solverIterations)
        value.toiIterationBudget = max(1, value.toiIterationBudget)
        value.contactTolerance = finiteNonnegative(value.contactTolerance, fallback: 0.001)
        value.separationTolerance = finiteNonnegative(value.separationTolerance, fallback: 0.002)
        value.positionTolerance = finiteNonnegative(value.positionTolerance, fallback: 0.0001)
        value.baseCompliance = finiteNonnegative(value.baseCompliance, fallback: 0.00001)
        value.nonlinearStiffening = finiteNonnegative(value.nonlinearStiffening, fallback: 8)
        value.linearDamping = finiteNonnegative(value.linearDamping, fallback: 1.5)
        value.angularDamping = finiteNonnegative(value.angularDamping, fallback: 2)
        value.surfaceFriction = min(1, finiteNonnegative(value.surfaceFriction, fallback: 0.2))
        value.maxContourSegmentLength = value.maxContourSegmentLength.isFinite && value.maxContourSegmentLength > 0
            ? value.maxContourSegmentLength : 8
        value.deformationRecoveryRate = finiteNonnegative(value.deformationRecoveryRate, fallback: 12)
        return value
    }

    private func finiteNonnegative(_ candidate: Float, fallback: Float) -> Float {
        candidate.isFinite && candidate >= 0 ? candidate : fallback
    }

    public static let `default` = ReferenceConfiguration()
}
