public enum RadialWorldStateError: Error, Equatable, Sendable {
    case duplicateBubbleID(BubbleID)
}

public struct RadialBubbleRange: Equatable, Sendable {
    public let bubbleIndex: Int
    public let sensorStart: Int
    public let sensorCount: Int

    public init(bubbleIndex: Int, sensorStart: Int, sensorCount: Int) {
        self.bubbleIndex = bubbleIndex
        self.sensorStart = sensorStart
        self.sensorCount = sensorCount
    }
}

public struct RadialWorldState: Equatable, Sendable {
    public private(set) var bubbles: [RadialBubbleState]
    public let ranges: [RadialBubbleRange]
    public let totalSensorCount: Int

    public init(bubbles: [RadialBubbleState]) throws {
        var knownIDs = Set<BubbleID>()
        var ranges: [RadialBubbleRange] = []
        ranges.reserveCapacity(bubbles.count)

        var sensorStart = 0
        for (bubbleIndex, bubble) in bubbles.enumerated() {
            guard knownIDs.insert(bubble.id).inserted else {
                throw RadialWorldStateError.duplicateBubbleID(bubble.id)
            }

            let sensorCount = bubble.sensors.count
            ranges.append(
                RadialBubbleRange(
                    bubbleIndex: bubbleIndex,
                    sensorStart: sensorStart,
                    sensorCount: sensorCount
                )
            )
            sensorStart += sensorCount
        }

        self.bubbles = bubbles
        self.ranges = ranges
        self.totalSensorCount = sensorStart
    }

    public func bubble(for id: BubbleID) -> RadialBubbleState? {
        bubbles.first { $0.id == id }
    }
}
