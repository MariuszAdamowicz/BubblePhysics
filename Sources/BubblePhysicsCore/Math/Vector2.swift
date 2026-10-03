import Foundation

public struct BPVector: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public static let zero = BPVector(x: 0, y: 0)

    public var lengthSquared: Double { x * x + y * y }
    public var length: Double { sqrt(lengthSquared) }
    public var isFinite: Bool { x.isFinite && y.isFinite }

    public func dot(_ other: BPVector) -> Double {
        x * other.x + y * other.y
    }

    public func cross(_ other: BPVector) -> Double {
        x * other.y - y * other.x
    }

    public func normalized(or fallback: BPVector) -> BPVector {
        let magnitude = length
        guard magnitude > 1e-12, magnitude.isFinite else { return fallback }
        return self / magnitude
    }
}

public prefix func - (value: BPVector) -> BPVector {
    BPVector(x: -value.x, y: -value.y)
}

public func + (lhs: BPVector, rhs: BPVector) -> BPVector {
    BPVector(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
}

public func - (lhs: BPVector, rhs: BPVector) -> BPVector {
    BPVector(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}

public func * (lhs: BPVector, rhs: Double) -> BPVector {
    BPVector(x: lhs.x * rhs, y: lhs.y * rhs)
}

public func * (lhs: Double, rhs: BPVector) -> BPVector {
    rhs * lhs
}

public func / (lhs: BPVector, rhs: Double) -> BPVector {
    BPVector(x: lhs.x / rhs, y: lhs.y / rhs)
}

public func += (lhs: inout BPVector, rhs: BPVector) {
    lhs = lhs + rhs
}

public func -= (lhs: inout BPVector, rhs: BPVector) {
    lhs = lhs - rhs
}
