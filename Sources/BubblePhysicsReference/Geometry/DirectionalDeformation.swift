public struct ReferenceContourConstraint: Sendable, Equatable {
    public var contactID: ReferenceContactID
    public var pointQ: ReferenceVector2
    public var inwardNormal: ReferenceVector2
    public var pressure: Float
    public var finiteSegment: ReferenceSegmentEndpoints?
    public var usesRoundedContactProfile: Bool

    public init(
        contactID: ReferenceContactID,
        pointQ: ReferenceVector2,
        inwardNormal: ReferenceVector2,
        pressure: Float,
        finiteSegment: ReferenceSegmentEndpoints? = nil,
        usesRoundedContactProfile: Bool = false
    ) {
        self.contactID = contactID
        self.pointQ = pointQ
        self.inwardNormal = inwardNormal.normalized(or: ReferenceVector2(x: 1, y: 0))
        self.pressure = max(0, pressure.isFinite ? pressure : 0)
        self.finiteSegment = finiteSegment
        self.usesRoundedContactProfile = usesRoundedContactProfile
    }
}
