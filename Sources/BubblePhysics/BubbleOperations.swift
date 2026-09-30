public enum BubbleOperationEvent: Equatable, Sendable {
    case resized(BubbleID, restArea: Float)
    case merged(inputs: [BubbleID], output: BubbleID)
    case split(input: BubbleID, outputs: [BubbleID])
}
