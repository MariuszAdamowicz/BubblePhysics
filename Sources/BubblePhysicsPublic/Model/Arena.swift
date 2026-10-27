/// Preset areny skonfigurowany przez właściciela świata. Wymiary i parametry fizyczne
/// pozostają poza żądaniem spawnu wysyłanym przez grę.
public struct ArenaPreset: Equatable, Sendable {
    public let id: String
    public let bounds: WorldRectangle
    public let bubbleRadius: Float
    public let physicsMaterialID: PhysicsMaterialID
    public let renderStyleID: RenderStyleID

    public init(id: String, bounds: WorldRectangle, bubbleRadius: Float,
                physicsMaterialID: PhysicsMaterialID, renderStyleID: RenderStyleID) throws {
        guard !id.isEmpty else { throw ModelValidationError.valueOutOfRange("arena.id") }
        try requirePositive(bubbleRadius, "arena.bubbleRadius")
        guard Double(bounds.max.x - bounds.min.x) >= Double(bubbleRadius) * 2,
              Double(bounds.max.y - bounds.min.y) >= Double(bubbleRadius) * 2 else {
            throw ModelValidationError.invalidRectangle
        }
        self.id = id; self.bounds = bounds; self.bubbleRadius = bubbleRadius
        self.physicsMaterialID = physicsMaterialID; self.renderStyleID = renderStyleID
    }
}

/// Semantyczne żądanie spawnu. Pozycję i prędkość wybiera silnik na podstawie areny i ziarna.
public struct SpawnBubbleRequest: Equatable, Sendable {
    public let value: Int
    public let arena: String
    public let seed: UInt64

    public init(value: Int, arena: String, seed: UInt64) {
        self.value = value; self.arena = arena; self.seed = seed
    }
}
