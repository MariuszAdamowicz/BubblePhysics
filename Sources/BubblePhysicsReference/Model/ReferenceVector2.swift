public struct ReferenceVector2: Sendable, Equatable, Hashable {
    public var x: Float
    public var y: Float

    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    public static let zero = ReferenceVector2(x: 0, y: 0)

    public var lengthSquared: Float { x * x + y * y }
    public var length: Float { lengthSquared.squareRoot() }
    public var isFinite: Bool { x.isFinite && y.isFinite }

    public func dot(_ other: ReferenceVector2) -> Float {
        x * other.x + y * other.y
    }

    public func cross(_ other: ReferenceVector2) -> Float {
        x * other.y - y * other.x
    }

    public func normalized(or fallback: ReferenceVector2 = .zero) -> ReferenceVector2 {
        let squared = lengthSquared
        guard squared.isFinite, squared > Float.ulpOfOne else { return fallback }
        return self / squared.squareRoot()
    }
}

public func + (lhs: ReferenceVector2, rhs: ReferenceVector2) -> ReferenceVector2 {
    .init(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

public func - (lhs: ReferenceVector2, rhs: ReferenceVector2) -> ReferenceVector2 {
    .init(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

public prefix func - (value: ReferenceVector2) -> ReferenceVector2 {
    .init(x: -value.x, y: -value.y)
}

public func * (lhs: ReferenceVector2, rhs: Float) -> ReferenceVector2 {
    .init(x: lhs.x * rhs, y: lhs.y * rhs)
}

public func * (lhs: Float, rhs: ReferenceVector2) -> ReferenceVector2 { rhs * lhs }

public func / (lhs: ReferenceVector2, rhs: Float) -> ReferenceVector2 {
    .init(x: lhs.x / rhs, y: lhs.y / rhs)
}
