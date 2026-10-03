public struct ReferenceContactSpringSample: Sendable, Equatable {
    public var compression: Float
    public var normal: ReferenceVector2
    public var forceOnA: ReferenceVector2
    public var tangentStiffness: Float

    public init(
        compression: Float,
        normal: ReferenceVector2,
        forceOnA: ReferenceVector2,
        tangentStiffness: Float
    ) {
        self.compression = compression
        self.normal = normal
        self.forceOnA = forceOnA
        self.tangentStiffness = tangentStiffness
    }
}

public enum ReferenceContactSpringState {
    public static func evaluate(
        centerA: ReferenceVector2,
        velocityA: ReferenceVector2,
        radiusA: Float,
        centerB: ReferenceVector2?,
        velocityB: ReferenceVector2,
        pointQ: ReferenceVector2?,
        normalFallback: ReferenceVector2,
        contactDistance: Float,
        stiffness: Float,
        damping: Float
    ) -> ReferenceContactSpringSample {
        _ = radiusA
        let anchor = centerB ?? pointQ ?? centerA
        let offset = centerA - anchor
        let fallback = normalFallback.normalized(or: .init(x: 1, y: 0))
        let geometricNormal = offset.normalized(or: fallback)
        let normal = centerB == nil && geometricNormal.dot(fallback) < 0
            ? fallback : geometricNormal
        let compression = max(0, contactDistance - offset.length)
        guard compression > 0 else {
            return .init(compression: 0, normal: normal, forceOnA: .zero, tangentStiffness: 0)
        }

        let relativeNormalVelocity = (velocityA - velocityB).dot(normal)
        let elasticMagnitude = max(0, stiffness) * compression
        let dampingMagnitude = max(0, damping) * relativeNormalVelocity
        let magnitude = max(0, elasticMagnitude - dampingMagnitude)
        return .init(
            compression: compression,
            normal: normal,
            forceOnA: normal * magnitude,
            tangentStiffness: magnitude > 0 ? max(0, stiffness) : 0
        )
    }
}
