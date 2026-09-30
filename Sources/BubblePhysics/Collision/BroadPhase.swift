public struct BroadPhaseDiagnostics: Equatable, Sendable {
    public let dirtyBodyCount: Int
    public let candidatePairCount: Int

    public init(dirtyBodyCount: Int, candidatePairCount: Int) {
        self.dirtyBodyCount = dirtyBodyCount
        self.candidatePairCount = candidatePairCount
    }
}

public struct BroadPhase: Sendable {
    private var boundsByBubble: [BubbleID: AABB] = [:]
    private var xIndex = EndpointIndex()
    private var yIndex = EndpointIndex()
    private var dirtyBodies: Set<BubbleID> = []
    private var cachedPairs: [BubblePair] = []
    public private(set) var diagnostics = BroadPhaseDiagnostics(dirtyBodyCount: 0, candidatePairCount: 0)

    public init() {}

    public var candidatePairs: [BubblePair] {
        cachedPairs
    }

    public mutating func upsert(_ bubbleID: BubbleID, bounds: AABB) {
        guard index(bubbleID, bounds: bounds) else { return }
        rebuildCandidates()
    }

    public mutating func upsert(_ updates: [(BubbleID, AABB)]) {
        for (bubbleID, bounds) in updates {
            _ = index(bubbleID, bounds: bounds)
        }
        guard !dirtyBodies.isEmpty else { return }
        rebuildCandidates()
    }

    private mutating func index(_ bubbleID: BubbleID, bounds: AABB) -> Bool {
        guard boundsByBubble[bubbleID] != bounds else { return false }
        boundsByBubble[bubbleID] = bounds
        xIndex.upsert(bubbleID, minimum: bounds.minimum.x, maximum: bounds.maximum.x)
        yIndex.upsert(bubbleID, minimum: bounds.minimum.y, maximum: bounds.maximum.y)
        dirtyBodies.insert(bubbleID)
        return true
    }

    public mutating func remove(_ bubbleID: BubbleID) {
        guard boundsByBubble.removeValue(forKey: bubbleID) != nil else { return }
        xIndex.remove(bubbleID)
        yIndex.remove(bubbleID)
        dirtyBodies.insert(bubbleID)
        rebuildCandidates()
    }

    private mutating func rebuildCandidates() {
        let xPairs = xIndex.overlappingPairs()
        let yPairs = yIndex.overlappingPairs()
        cachedPairs = xPairs.intersection(yPairs).filter { pair in
            guard let first = boundsByBubble[pair.first], let second = boundsByBubble[pair.second] else { return false }
            return first.intersects(second)
        }.sorted()
        diagnostics = BroadPhaseDiagnostics(dirtyBodyCount: dirtyBodies.count, candidatePairCount: cachedPairs.count)
        dirtyBodies.removeAll(keepingCapacity: true)
    }
}

private extension AABB {
    func intersects(_ other: AABB) -> Bool {
        minimum.x <= other.maximum.x && maximum.x >= other.minimum.x && minimum.y <= other.maximum.y && maximum.y >= other.minimum.y
    }
}
