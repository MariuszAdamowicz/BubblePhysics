public struct ReferenceAABB: Sendable, Equatable {
    public var minimum: ReferenceVector2
    public var maximum: ReferenceVector2

    public init(minimum: ReferenceVector2, maximum: ReferenceVector2) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func overlaps(_ other: ReferenceAABB) -> Bool {
        minimum.x <= other.maximum.x && maximum.x >= other.minimum.x
            && minimum.y <= other.maximum.y && maximum.y >= other.minimum.y
    }

    public func expanded(by amount: Float) -> ReferenceAABB {
        let offset = ReferenceVector2(x: amount, y: amount)
        return .init(minimum: minimum - offset, maximum: maximum + offset)
    }
}
