/// Liczba żądanych zdarzeń, których nie zmieścił ograniczony bufor klatki.
public struct WorldEventOverflow: Equatable, Sendable {
    public let droppedCount: Int
    public var didOverflow: Bool { droppedCount > 0 }
    public init(droppedCount: Int = 0) { self.droppedCount = max(0, droppedCount) }
}
