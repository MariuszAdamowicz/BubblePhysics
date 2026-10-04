public struct ReferenceContainmentTracker: Sendable, Equatable {
    public private(set) var maximumConsecutiveFrames = 0
    public var positionTolerance: Float

    private var activeCounts: [BubblePair: Int] = [:]

    public init(positionTolerance: Float = ReferenceConfiguration.default.positionTolerance) {
        self.positionTolerance = max(0, positionTolerance.isFinite ? positionTolerance : 0)
    }

    public mutating func observe(_ bubbles: [ReferenceBubble]) {
        var next: [BubblePair: Int] = [:]
        guard bubbles.count > 1 else {
            activeCounts = next
            return
        }
        for firstIndex in 0..<(bubbles.count - 1) {
            for secondIndex in (firstIndex + 1)..<bubbles.count {
                let first = bubbles[firstIndex]
                let second = bubbles[secondIndex]
                let distance = (second.center - first.center).length
                let smallerRadius = min(first.targetRadius, second.targetRadius)
                let largerRadius = max(first.targetRadius, second.targetRadius)
                guard distance + smallerRadius < largerRadius - positionTolerance else { continue }
                let pair = BubblePair(first.id, second.id)
                let count = activeCounts[pair, default: 0] + 1
                next[pair] = count
                maximumConsecutiveFrames = max(maximumConsecutiveFrames, count)
            }
        }
        activeCounts = next
    }

    private struct BubblePair: Sendable, Equatable, Hashable {
        var first: ReferenceBubbleID
        var second: ReferenceBubbleID

        init(_ lhs: ReferenceBubbleID, _ rhs: ReferenceBubbleID) {
            first = min(lhs, rhs)
            second = max(lhs, rhs)
        }
    }
}
