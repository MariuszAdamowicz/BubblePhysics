public struct GrabState: Equatable, Sendable {
    public let id: GrabID
    public let bubbleID: BubbleID
    public private(set) var target: Vector2
    public private(set) var resistance: Float

    init(id: GrabID, bubbleID: BubbleID, target: Vector2, resistance: Float = 0) {
        self.id = id
        self.bubbleID = bubbleID
        self.target = target
        self.resistance = resistance
    }

    mutating func update(target: Vector2, resistance: Float) {
        self.target = target
        self.resistance = resistance
    }
}
