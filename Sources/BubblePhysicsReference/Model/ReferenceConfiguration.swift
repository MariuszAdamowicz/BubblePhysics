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
    public var angularFrictionCoupling: Float
    public var toiIterationBudget: Int
    public var maxContourSegmentLength: Float
    public var deformationRecoveryRate: Float
    public var maximumContactPressure: Float
    public var pcgTolerance: Float
    public var pcgIterationLimit: Int
    public var stressTolerance: Float
    public var contactStiffness: Float
    public var contactDamping: Float
    public var simultaneousEventTolerance: Float
    public var maximumEventGroups: Int
    public var contourSurfaceTension: Float

    public init(
        timeStep: Float = 1 / 60,
        solverIterations: Int = 4,
        contactTolerance: Float = 0.001,
        separationTolerance: Float = 0.002,
        positionTolerance: Float = 0.0001,
        baseCompliance: Float = 0.00001,
        nonlinearStiffening: Float = 8,
        linearDamping: Float = 1.5,
        angularDamping: Float = 2,
        surfaceFriction: Float = 0.2,
        angularFrictionCoupling: Float = 1,
        toiIterationBudget: Int = 8,
        maxContourSegmentLength: Float = 8,
        deformationRecoveryRate: Float = 12,
        maximumContactPressure: Float = 1_000_000,
        pcgTolerance: Float = 0.001,
        pcgIterationLimit: Int = 24,
        stressTolerance: Float = 0.01,
        contactStiffness: Float = 120,
        contactDamping: Float = 8,
        simultaneousEventTolerance: Float = 1e-5,
        maximumEventGroups: Int = 8,
        contourSurfaceTension: Float = 20
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
        self.angularFrictionCoupling = angularFrictionCoupling
        self.toiIterationBudget = toiIterationBudget
        self.maxContourSegmentLength = maxContourSegmentLength
        self.deformationRecoveryRate = deformationRecoveryRate
        self.maximumContactPressure = maximumContactPressure
        self.pcgTolerance = pcgTolerance
        self.pcgIterationLimit = pcgIterationLimit
        self.stressTolerance = stressTolerance
        self.contactStiffness = contactStiffness
        self.contactDamping = contactDamping
        self.simultaneousEventTolerance = simultaneousEventTolerance
        self.maximumEventGroups = maximumEventGroups
        self.contourSurfaceTension = contourSurfaceTension
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
        value.angularFrictionCoupling = value.angularFrictionCoupling.isFinite
            ? min(1, max(0, value.angularFrictionCoupling)) : 1
        value.maxContourSegmentLength = value.maxContourSegmentLength.isFinite && value.maxContourSegmentLength > 0
            ? value.maxContourSegmentLength : 8
        value.deformationRecoveryRate = finiteNonnegative(value.deformationRecoveryRate, fallback: 12)
        value.maximumContactPressure = value.maximumContactPressure.isFinite && value.maximumContactPressure > 0
            ? value.maximumContactPressure : 1_000_000
        value.pcgTolerance = value.pcgTolerance.isFinite && value.pcgTolerance > 0 ? value.pcgTolerance : 0.001
        value.pcgIterationLimit = max(1, value.pcgIterationLimit)
        value.stressTolerance = value.stressTolerance.isFinite && value.stressTolerance > 0 ? value.stressTolerance : 0.01
        value.contactStiffness = value.contactStiffness.isFinite && value.contactStiffness > 0
            ? value.contactStiffness : 120
        value.contactDamping = finiteNonnegative(value.contactDamping, fallback: 8)
        value.simultaneousEventTolerance = finiteNonnegative(value.simultaneousEventTolerance, fallback: 1e-5)
        value.maximumEventGroups = max(1, value.maximumEventGroups)
        value.contourSurfaceTension = finiteNonnegative(value.contourSurfaceTension, fallback: 20)
        return value
    }

    private func finiteNonnegative(_ candidate: Float, fallback: Float) -> Float {
        candidate.isFinite && candidate >= 0 ? candidate : fallback
    }

    public static let `default` = ReferenceConfiguration()
}
