/// Semantyczna prezentacja należąca do silnika. Nie zawiera geometrii ani stylu produktu.
public struct BubblePresentation: Equatable, Sendable {
    public let value: Int
    public let isGrabbed: Bool

    public init(value: Int, isGrabbed: Bool) throws {
        guard value > 0 else { throw ModelValidationError.valueOutOfRange("bubblePresentation.value") }
        self.value = value
        self.isGrabbed = isGrabbed
    }
}
