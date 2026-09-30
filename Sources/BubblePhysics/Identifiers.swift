public struct BubbleID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (left: BubbleID, right: BubbleID) -> Bool {
        left.rawValue < right.rawValue
    }
}

public struct PolygonID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (left: PolygonID, right: PolygonID) -> Bool {
        left.rawValue < right.rawValue
    }
}

public struct GrabID: RawRepresentable, Hashable, Comparable, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static func < (left: GrabID, right: GrabID) -> Bool {
        left.rawValue < right.rawValue
    }
}
