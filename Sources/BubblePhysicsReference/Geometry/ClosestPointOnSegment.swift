public struct ReferenceSegmentEndpoints: Sendable, Equatable {
    public var a: ReferenceVector2
    public var b: ReferenceVector2

    public init(a: ReferenceVector2, b: ReferenceVector2) {
        self.a = a
        self.b = b
    }
}

public struct ClosestPointResult: Sendable, Equatable {
    public var point: ReferenceVector2
    public var t: Float
    public var distanceSquared: Float

    public init(point: ReferenceVector2, t: Float, distanceSquared: Float) {
        self.point = point
        self.t = t
        self.distanceSquared = distanceSquared
    }
}

public func closestPoint(
    to point: ReferenceVector2,
    on segment: ReferenceSegmentEndpoints
) -> ClosestPointResult {
    let edge = segment.b - segment.a
    let lengthSquared = edge.lengthSquared
    guard lengthSquared > Float.ulpOfOne, lengthSquared.isFinite else {
        let delta = point - segment.a
        return ClosestPointResult(point: segment.a, t: 0, distanceSquared: delta.lengthSquared)
    }

    let unclampedT = (point - segment.a).dot(edge) / lengthSquared
    let t = min(1, max(0, unclampedT))
    let closest = segment.a + edge * t
    return ClosestPointResult(point: closest, t: t, distanceSquared: (point - closest).lengthSquared)
}
