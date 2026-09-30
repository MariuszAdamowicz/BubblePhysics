public struct BubblePose: Equatable, Sendable {
    public let center: Vector2
    public let boundaryPoints: [Vector2]
    public let materialAxis: Vector2

    public init(center: Vector2, boundaryPoints: [Vector2], materialAxis: Vector2) {
        self.center = center
        self.boundaryPoints = boundaryPoints
        self.materialAxis = materialAxis
    }
}
