public struct BubblePair: Hashable, Comparable, Sendable {
    public let first: BubbleID
    public let second: BubbleID

    public init(_ first: BubbleID, _ second: BubbleID) {
        precondition(first != second)
        self.first = min(first, second)
        self.second = max(first, second)
    }

    public static func < (left: BubblePair, right: BubblePair) -> Bool {
        left.first == right.first ? left.second < right.second : left.first < right.first
    }
}

public struct ContactGraph: Sendable {
    private var activePairs: Set<BubblePair> = []

    public init() {}

    public var pairs: [BubblePair] {
        activePairs.sorted()
    }

    public mutating func synchronize(with candidates: [BubblePair]) {
        activePairs = Set(candidates)
    }
}
