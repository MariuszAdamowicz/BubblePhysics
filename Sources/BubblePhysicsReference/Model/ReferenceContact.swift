public struct ReferenceContactID: Sendable, Equatable, Hashable, Comparable {
    public var rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static func < (lhs: ReferenceContactID, rhs: ReferenceContactID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ReferenceContactKind: Sendable, Equatable {
    case bubbleBubble
    case bubbleSegment
}

public struct ReferenceContact: Sendable, Equatable {
    public var id: ReferenceContactID
    public var kind: ReferenceContactKind
    public var bubbleA: ReferenceBubbleID
    public var bubbleB: ReferenceBubbleID?
    public var segment: ReferenceSegmentID?
    public var normal: ReferenceVector2
    public var pointQ: ReferenceVector2
    public var penetration: Float
    public var timeOfImpact: Float?
    public var allowedSide: Float?
    public var accumulatedCompression: Float
    public var compressionA: Float
    public var compressionB: Float
    public var pressure: Float
    public var effectiveStiffness: Float
    public var age: Int
    public var contourHalfLength: Float?

    public init(
        id: ReferenceContactID,
        kind: ReferenceContactKind,
        bubbleA: ReferenceBubbleID,
        bubbleB: ReferenceBubbleID? = nil,
        segment: ReferenceSegmentID? = nil,
        normal: ReferenceVector2,
        pointQ: ReferenceVector2,
        penetration: Float,
        timeOfImpact: Float? = nil,
        allowedSide: Float? = nil,
        accumulatedCompression: Float = 0,
        compressionA: Float = 0,
        compressionB: Float = 0,
        pressure: Float = 0,
        effectiveStiffness: Float = 0,
        age: Int = 0,
        contourHalfLength: Float? = nil
    ) {
        self.id = id
        self.kind = kind
        self.bubbleA = bubbleA
        self.bubbleB = bubbleB
        self.segment = segment
        self.normal = normal
        self.pointQ = pointQ
        self.penetration = penetration
        self.timeOfImpact = timeOfImpact
        self.allowedSide = allowedSide
        self.accumulatedCompression = accumulatedCompression
        self.compressionA = compressionA
        self.compressionB = compressionB
        self.pressure = pressure
        self.effectiveStiffness = effectiveStiffness
        self.age = age
        self.contourHalfLength = contourHalfLength
    }
}
