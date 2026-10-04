public struct ReferenceProxyID: Sendable, Equatable, Hashable, Comparable {
    public var rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: ReferenceProxyID, rhs: ReferenceProxyID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct ReferenceProxy: Sendable, Equatable {
    public var id: ReferenceProxyID
    public var bounds: ReferenceAABB

    public init(id: ReferenceProxyID, bounds: ReferenceAABB) {
        self.id = id
        self.bounds = bounds
    }
}

public struct ReferencePair: Sendable, Equatable, Hashable, Comparable {
    public var first: ReferenceProxyID
    public var second: ReferenceProxyID

    public init(_ first: ReferenceProxyID, _ second: ReferenceProxyID) {
        self.first = min(first, second)
        self.second = max(first, second)
    }

    public static func < (lhs: ReferencePair, rhs: ReferencePair) -> Bool {
        lhs.first == rhs.first ? lhs.second < rhs.second : lhs.first < rhs.first
    }
}

public protocol ReferenceBroadPhase {
    mutating func candidatePairs(for proxies: [ReferenceProxy]) -> [ReferencePair]
}
