public struct DirectionalDeformation: Sendable, Equatable {
    public var contactID: ReferenceContactID
    public var direction: ReferenceVector2
    public var depth: Float
    public var angularWidth: Float
    public var pressure: Float

    public init(
        contactID: ReferenceContactID,
        direction: ReferenceVector2,
        depth: Float,
        angularWidth: Float,
        pressure: Float
    ) {
        self.contactID = contactID
        self.direction = direction.normalized(or: ReferenceVector2(x: 1, y: 0))
        self.depth = max(0, depth.isFinite ? depth : 0)
        self.angularWidth = max(Float.ulpOfOne, angularWidth.isFinite ? angularWidth : Float.ulpOfOne)
        self.pressure = max(0, pressure.isFinite ? pressure : 0)
    }
}
