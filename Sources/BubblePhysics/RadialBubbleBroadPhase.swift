public struct RadialBubblePair: Equatable, Hashable, Sendable {
    public let firstID: BubbleID
    public let secondID: BubbleID

    public init(firstID: BubbleID, secondID: BubbleID) {
        precondition(firstID != secondID)
        self.firstID = min(firstID, secondID)
        self.secondID = max(firstID, secondID)
    }
}

public enum RadialBubbleBroadPhase {
    public static func candidates(in world: RadialWorldState, deltaTime: Float) -> [RadialBubblePair] {
        precondition(deltaTime >= 0)
        let entries = world.bubbles.compactMap { bubble -> (RadialBubbleState, AABB)? in
            let offset = bubble.body.linearVelocity * deltaTime
            let sweptPoints = bubble.surfacePoints.flatMap { [$0, $0 + offset] }
            guard let bounds = AABB.enclosing(sweptPoints) else { return nil }
            return (bubble, bounds)
        }.sorted {
            if $0.1.minimum.x != $1.1.minimum.x { return $0.1.minimum.x < $1.1.minimum.x }
            return $0.0.id < $1.0.id
        }

        var pairs: [RadialBubblePair] = []
        for firstIndex in entries.indices {
            let first = entries[firstIndex]
            for secondIndex in entries.index(after: firstIndex)..<entries.endIndex {
                let second = entries[secondIndex]
                if second.1.minimum.x > first.1.maximum.x { break }
                guard second.1.maximum.y >= first.1.minimum.y,
                      second.1.minimum.y <= first.1.maximum.y else { continue }
                pairs.append(RadialBubblePair(firstID: first.0.id, secondID: second.0.id))
            }
        }
        return pairs.sorted {
            $0.firstID != $1.firstID ? $0.firstID < $1.firstID : $0.secondID < $1.secondID
        }
    }
}
