public struct AABBTreeBroadPhase: ReferenceBroadPhase, Sendable {
    private indirect enum Node: Sendable {
        case leaf(ReferenceProxy)
        case branch(bounds: ReferenceAABB, left: Node, right: Node)

        var bounds: ReferenceAABB {
            switch self {
            case let .leaf(proxy): proxy.bounds
            case let .branch(bounds, _, _): bounds
            }
        }
    }

    public init() {}

    public mutating func candidatePairs(for proxies: [ReferenceProxy]) -> [ReferencePair] {
        guard let root = build(proxies) else { return [] }
        var pairs: [ReferencePair] = []
        for proxy in proxies {
            query(proxy, node: root, pairs: &pairs)
        }
        return Array(Set(pairs)).sorted()
    }

    private func build(_ proxies: [ReferenceProxy]) -> Node? {
        guard !proxies.isEmpty else { return nil }
        if proxies.count == 1 { return .leaf(proxies[0]) }

        let combined = proxies.dropFirst().reduce(proxies[0].bounds) { union($0, $1.bounds) }
        let width = combined.maximum.x - combined.minimum.x
        let height = combined.maximum.y - combined.minimum.y
        let sorted = proxies.sorted {
            let firstCenter = center(of: $0.bounds)
            let secondCenter = center(of: $1.bounds)
            let firstValue = width >= height ? firstCenter.x : firstCenter.y
            let secondValue = width >= height ? secondCenter.x : secondCenter.y
            return firstValue == secondValue ? $0.id < $1.id : firstValue < secondValue
        }
        let middle = sorted.count / 2
        guard let left = build(Array(sorted[..<middle])),
              let right = build(Array(sorted[middle...])) else { return nil }
        return .branch(bounds: union(left.bounds, right.bounds), left: left, right: right)
    }

    private func query(_ proxy: ReferenceProxy, node: Node, pairs: inout [ReferencePair]) {
        guard proxy.bounds.overlaps(node.bounds) else { return }
        switch node {
        case let .leaf(other):
            guard proxy.id < other.id, proxy.bounds.overlaps(other.bounds) else { return }
            pairs.append(ReferencePair(proxy.id, other.id))
        case let .branch(_, left, right):
            query(proxy, node: left, pairs: &pairs)
            query(proxy, node: right, pairs: &pairs)
        }
    }

    private func union(_ first: ReferenceAABB, _ second: ReferenceAABB) -> ReferenceAABB {
        ReferenceAABB(
            minimum: .init(
                x: min(first.minimum.x, second.minimum.x),
                y: min(first.minimum.y, second.minimum.y)
            ),
            maximum: .init(
                x: max(first.maximum.x, second.maximum.x),
                y: max(first.maximum.y, second.maximum.y)
            )
        )
    }

    private func center(of bounds: ReferenceAABB) -> ReferenceVector2 {
        (bounds.minimum + bounds.maximum) * 0.5
    }
}
