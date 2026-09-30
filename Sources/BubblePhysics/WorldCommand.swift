public enum WorldCommand: Equatable, Sendable {
    case setGravity(Vector2)
    case applyForce(BubbleID, Vector2)
    case setKinematicTransform(PolygonID, position: Vector2, angleRadians: Float, linearVelocity: Vector2, angularVelocity: Float)
}
