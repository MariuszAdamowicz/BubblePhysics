public struct SweepAndPruneBroadPhase: ReferenceBroadPhase, Sendable {
    private var sorted: [ReferenceProxy] = []

    public init() {}

    public mutating func candidatePairs(for proxies: [ReferenceProxy]) -> [ReferencePair] {
        sorted = proxies.sorted {
            if $0.bounds.minimum.x != $1.bounds.minimum.x {
                return $0.bounds.minimum.x < $1.bounds.minimum.x
            }
            return $0.id < $1.id
        }

        var active: [ReferenceProxy] = []
        var pairs: [ReferencePair] = []
        for proxy in sorted {
            active.removeAll { $0.bounds.maximum.x < proxy.bounds.minimum.x }
            for candidate in active where candidate.bounds.overlaps(proxy.bounds) {
                pairs.append(ReferencePair(candidate.id, proxy.id))
            }
            active.append(proxy)
        }
        return pairs.sorted()
    }
}
