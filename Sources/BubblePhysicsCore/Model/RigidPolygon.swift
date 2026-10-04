public struct RigidPolygon: Equatable, Sendable {
    public var localVertices: [BPVector]
    public var position: BPVector
    public var angle: Double
    public var linearVelocity: BPVector
    public var angularVelocity: Double

    public init(
        localVertices: [BPVector],
        position: BPVector,
        angle: Double = 0,
        linearVelocity: BPVector = .zero,
        angularVelocity: Double = 0
    ) {
        self.localVertices = localVertices
        self.position = position
        self.angle = angle
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
    }
}
