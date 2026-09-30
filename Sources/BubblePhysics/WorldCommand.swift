public enum WorldCommand: Equatable, Sendable {
    case setGravity(Vector2)
    case applyForce(BubbleID, Vector2)
}
