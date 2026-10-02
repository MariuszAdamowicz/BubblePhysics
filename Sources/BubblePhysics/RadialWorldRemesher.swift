public struct RadialRemeshPolicy: Equatable, Sendable {
    public var upperSegmentLengthRatio: Float
    public var lowerSegmentLengthRatio: Float
    public var cooldownFrames: Int

    public init(
        upperSegmentLengthRatio: Float = 1,
        lowerSegmentLengthRatio: Float = 0.65,
        cooldownFrames: Int = 15
    ) {
        precondition(upperSegmentLengthRatio > 0)
        precondition(lowerSegmentLengthRatio > 0)
        precondition(lowerSegmentLengthRatio < upperSegmentLengthRatio)
        precondition(cooldownFrames > 0)
        self.upperSegmentLengthRatio = upperSegmentLengthRatio
        self.lowerSegmentLengthRatio = lowerSegmentLengthRatio
        self.cooldownFrames = cooldownFrames
    }

    public static let `default` = RadialRemeshPolicy()
}

public struct RadialRemeshDecision: Equatable, Sendable {
    public let bubbleID: BubbleID
    public let sensorCount: Int
    public let frameIndex: Int

    public init(bubbleID: BubbleID, sensorCount: Int, frameIndex: Int) {
        precondition(sensorCount >= 8)
        self.bubbleID = bubbleID
        self.sensorCount = sensorCount
        self.frameIndex = frameIndex
    }
}

public enum RadialWorldRemesher {
    public static func plan(
        world: RadialWorldState,
        policy: RadialRemeshPolicy,
        frameIndex: Int
    ) -> [RadialRemeshDecision] {
        let cooldownBoundary = frameIndex.isMultiple(of: policy.cooldownFrames)

        return world.bubbles.compactMap { bubble in
            let maximumLength = RadialSensorRemesher.maximumSegmentLength(in: bubble)
            let upperThreshold = bubble.maxSegmentLength * policy.upperSegmentLengthRatio
            let lowerThreshold = bubble.maxSegmentLength * policy.lowerSegmentLengthRatio
            let urgentGrowth = maximumLength > upperThreshold * 2

            let shouldGrow = maximumLength > upperThreshold
            let shouldShrink = maximumLength < lowerThreshold && bubble.sensors.count > 8
            guard (cooldownBoundary || urgentGrowth), shouldGrow || shouldShrink else { return nil }

            let targetCount = RadialSensorRemesher.requiredCount(
                for: bubble,
                maxSegmentLength: bubble.maxSegmentLength
            )
            guard targetCount != bubble.sensors.count else { return nil }
            return RadialRemeshDecision(
                bubbleID: bubble.id,
                sensorCount: targetCount,
                frameIndex: frameIndex
            )
        }
    }

    public static func apply(
        _ decisions: [RadialRemeshDecision],
        to world: RadialWorldState
    ) throws -> RadialWorldState {
        let decisionsByID = Dictionary(uniqueKeysWithValues: decisions.map { ($0.bubbleID, $0) })
        let bubbles = world.bubbles.map { bubble -> RadialBubbleState in
            guard let decision = decisionsByID[bubble.id] else { return bubble }
            return RadialSensorRemesher.resample(bubble, to: decision.sensorCount)
        }
        return try RadialWorldState(bubbles: bubbles)
    }
}
