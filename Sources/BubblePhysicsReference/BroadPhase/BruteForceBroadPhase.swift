public struct BruteForceBroadPhase: ReferenceBroadPhase, Sendable {
    public init() {}

    public mutating func candidatePairs(for proxies: [ReferenceProxy]) -> [ReferencePair] {
        guard proxies.count > 1 else { return [] }
        var pairs: [ReferencePair] = []
        for firstIndex in 0..<(proxies.count - 1) {
            for secondIndex in (firstIndex + 1)..<proxies.count
            where proxies[firstIndex].bounds.overlaps(proxies[secondIndex].bounds) {
                pairs.append(ReferencePair(proxies[firstIndex].id, proxies[secondIndex].id))
            }
        }
        return Array(Set(pairs)).sorted()
    }
}
