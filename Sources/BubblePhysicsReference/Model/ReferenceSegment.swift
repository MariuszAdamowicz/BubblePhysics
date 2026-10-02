public struct ReferenceSegmentID: Sendable, Equatable, Hashable, Comparable {
    public var rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: ReferenceSegmentID, rhs: ReferenceSegmentID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ReferenceSegmentMotion: Sendable, Equatable {
    case staticBody
    case kinematic
}

public enum ReferenceSegmentCollisionMode: Sendable, Equatable {
    case oneSided(allowedSide: Float)
    case twoSided

    public var allowedSide: Float? {
        switch self {
        case let .oneSided(allowedSide): allowedSide < 0 ? -1 : 1
        case .twoSided: nil
        }
    }

    fileprivate var normalized: ReferenceSegmentCollisionMode {
        guard let allowedSide else { return .twoSided }
        return .oneSided(allowedSide: allowedSide)
    }
}

public struct ReferenceSegment: Sendable, Equatable {
    public var id: ReferenceSegmentID
    public var previousA: ReferenceVector2
    public var previousB: ReferenceVector2
    public var currentA: ReferenceVector2
    public var currentB: ReferenceVector2
    public var linearVelocity: ReferenceVector2
    public var angularVelocity: Float
    public var motion: ReferenceSegmentMotion
    public var ownerID: Int?
    public var collisionMode: ReferenceSegmentCollisionMode

    public static func staticSegment(
        id: ReferenceSegmentID,
        a: ReferenceVector2,
        b: ReferenceVector2,
        ownerID: Int? = nil,
        collisionMode: ReferenceSegmentCollisionMode = .twoSided
    ) -> ReferenceSegment {
        ReferenceSegment(
            id: id,
            previousA: a,
            previousB: b,
            currentA: a,
            currentB: b,
            linearVelocity: .zero,
            angularVelocity: 0,
            motion: .staticBody,
            ownerID: ownerID,
            collisionMode: collisionMode.normalized
        )
    }

    public static func kinematicSegment(
        id: ReferenceSegmentID,
        previousA: ReferenceVector2,
        previousB: ReferenceVector2,
        currentA: ReferenceVector2,
        currentB: ReferenceVector2,
        timeStep: Float = ReferenceConfiguration.default.timeStep,
        angularVelocity: Float = 0,
        ownerID: Int? = nil,
        collisionMode: ReferenceSegmentCollisionMode = .twoSided
    ) -> ReferenceSegment {
        let previousCenter = (previousA + previousB) * 0.5
        let currentCenter = (currentA + currentB) * 0.5
        return ReferenceSegment(
            id: id,
            previousA: previousA,
            previousB: previousB,
            currentA: currentA,
            currentB: currentB,
            linearVelocity: (currentCenter - previousCenter) / max(timeStep, Float.ulpOfOne),
            angularVelocity: angularVelocity,
            motion: .kinematic,
            ownerID: ownerID,
            collisionMode: collisionMode.normalized
        )
    }
}
