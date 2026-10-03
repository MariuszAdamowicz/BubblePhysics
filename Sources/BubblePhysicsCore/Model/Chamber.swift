public struct Chamber: Equatable, Sendable {
    public var minimum: BPVector
    public var maximum: BPVector

    public init(minimum: BPVector, maximum: BPVector) {
        self.minimum = minimum
        self.maximum = maximum
    }

    public func contains(_ point: BPVector, tolerance: Double) -> Bool {
        point.x >= minimum.x - tolerance
            && point.x <= maximum.x + tolerance
            && point.y >= minimum.y - tolerance
            && point.y <= maximum.y + tolerance
    }
}
