public struct ReferenceBubbleID: Sendable, Equatable, Hashable, Comparable {
    public var rawValue: Int

    public init(rawValue: Int) { self.rawValue = rawValue }

    public static func < (lhs: ReferenceBubbleID, rhs: ReferenceBubbleID) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public enum ReferenceModelError: Error, Equatable {
    case nonFiniteValue
    case nonPositiveMass
    case nonPositiveRadius
}

public struct ReferenceBubble: Sendable, Equatable {
    public var id: ReferenceBubbleID
    public var center: ReferenceVector2
    public var previousCenter: ReferenceVector2
    public var velocity: ReferenceVector2
    public var mass: Float
    public var inverseMass: Float
    public var targetRadius: Float
    public var stiffness: Float
    public var rotation: Float
    public var angularVelocity: Float
    public var directionalDeformations: [DirectionalDeformation]

    public init(
        id: ReferenceBubbleID,
        center: ReferenceVector2,
        velocity: ReferenceVector2 = .zero,
        mass: Float,
        targetRadius: Float,
        stiffness: Float = 1,
        rotation: Float = 0,
        angularVelocity: Float = 0,
        directionalDeformations: [DirectionalDeformation] = []
    ) throws {
        guard center.isFinite, velocity.isFinite, mass.isFinite, targetRadius.isFinite,
              stiffness.isFinite, rotation.isFinite, angularVelocity.isFinite else {
            throw ReferenceModelError.nonFiniteValue
        }
        guard mass > 0 else { throw ReferenceModelError.nonPositiveMass }
        guard targetRadius > 0 else { throw ReferenceModelError.nonPositiveRadius }

        self.id = id
        self.center = center
        self.previousCenter = center
        self.velocity = velocity
        self.mass = mass
        self.inverseMass = 1 / mass
        self.targetRadius = targetRadius
        self.stiffness = stiffness
        self.rotation = rotation
        self.angularVelocity = angularVelocity
        self.directionalDeformations = directionalDeformations
    }

    public var targetBounds: ReferenceAABB {
        ReferenceAABB(
            minimum: center - ReferenceVector2(x: targetRadius, y: targetRadius),
            maximum: center + ReferenceVector2(x: targetRadius, y: targetRadius)
        )
    }
}
