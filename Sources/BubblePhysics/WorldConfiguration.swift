import Foundation

public struct WorldConfiguration: Equatable, Sendable {
    public let fixedTimeStep: Float
    public let solverIterations: Int
    public let maxBoundarySegmentLength: Float
    public let linearDamping: Float
    public let springMaterial: SpringMaterial

    public init(
        fixedTimeStep: Float,
        solverIterations: Int,
        maxBoundarySegmentLength: Float,
        linearDamping: Float,
        springMaterial: SpringMaterial? = nil
    ) {
        self.fixedTimeStep = fixedTimeStep
        self.solverIterations = solverIterations
        self.maxBoundarySegmentLength = maxBoundarySegmentLength
        self.linearDamping = linearDamping
        if let springMaterial {
            self.springMaterial = springMaterial
        } else {
            let clampedDamping = max(0, min(linearDamping, 0.999_999))
            let drag = fixedTimeStep > 0 ? -log(1 - clampedDamping) / fixedTimeStep : 0
            self.springMaterial = SpringMaterial(
                quadraticStiffness: SpringMaterial.default.quadraticStiffness,
                quarticStiffness: SpringMaterial.default.quarticStiffness,
                drag: drag
            )
        }
    }

    public static let `default` = WorldConfiguration(
        fixedTimeStep: 1.0 / 60.0,
        solverIterations: 8,
        maxBoundarySegmentLength: 8,
        linearDamping: 0.05,
        springMaterial: .default
    )
}
