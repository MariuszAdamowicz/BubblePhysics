public struct AABB: Equatable, Sendable {
    public let minimum: Vector2
    public let maximum: Vector2

    public init(minimum: Vector2, maximum: Vector2) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public static func enclosing(_ points: [Vector2]) -> AABB? {
        guard let first = points.first else { return nil }
        var minimum = first
        var maximum = first
        for point in points.dropFirst() {
            minimum = Vector2(x: Swift.min(minimum.x, point.x), y: Swift.min(minimum.y, point.y))
            maximum = Vector2(x: Swift.max(maximum.x, point.x), y: Swift.max(maximum.y, point.y))
        }
        return AABB(minimum: minimum, maximum: maximum)
    }
}
