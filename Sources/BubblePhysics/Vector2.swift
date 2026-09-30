public struct Vector2: Equatable, Hashable, Sendable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public static let zero = Vector2(x: 0, y: 0)

    public func dot(_ other: Vector2) -> Float {
        x * other.x + y * other.y
    }
}

public func + (left: Vector2, right: Vector2) -> Vector2 {
    Vector2(x: left.x + right.x, y: left.y + right.y)
}

public func - (left: Vector2, right: Vector2) -> Vector2 {
    Vector2(x: left.x - right.x, y: left.y - right.y)
}

public func * (vector: Vector2, scalar: Float) -> Vector2 {
    Vector2(x: vector.x * scalar, y: vector.y * scalar)
}
