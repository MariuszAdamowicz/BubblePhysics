import Foundation

public struct JointID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Zakres kąta zawiasu w radianach, względem `Joint.referenceAngle`.
public struct HingeLimits: Equatable, Sendable {
    public let lower: Float
    public let upper: Float
    public init(lower: Float, upper: Float) throws {
        try requireFinite(lower, "hinge.lower")
        try requireFinite(upper, "hinge.upper")
        guard lower <= upper else { throw ModelValidationError.valueOutOfRange("hinge.limits") }
        self.lower = lower; self.upper = upper
    }
}

/// Silnik zawiasu: dąży do docelowej prędkości kątowej ciała B względem A, nie przekraczając maksymalnego momentu.
public struct HingeMotor: Equatable, Sendable {
    public let targetAngularVelocity: Float
    public let maximumTorque: Float
    public init(targetAngularVelocity: Float, maximumTorque: Float) throws {
        try requireFinite(targetAngularVelocity, "hinge.motor.targetAngularVelocity")
        try requirePositive(maximumTorque, "hinge.motor.maximumTorque")
        self.targetAngularVelocity = targetAngularVelocity; self.maximumTorque = maximumTorque
    }
}

/// Więz między ciałem A a ciałem B albo światem (`bodyB == nil`). Kotwice leżą w układach lokalnych ciał;
/// dla świata `anchorB` jest punktem świata. Bańka (zaczepiona w środku masy) może być tylko w więzie dystansowym.
/// Względny kąt ciał to `rotacja(B) − rotacja(A) − referenceAngle`, a dla świata rotacja B wynosi 0.
public struct Joint: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// `softness` to podatność XPBD (0 = sztywny dystans), `damping` tłumi prędkość względną wzdłuż więzu.
        case distance(length: Float, softness: Float, damping: Float)
        case hinge(limits: HingeLimits?, motor: HingeMotor?)
        case weld
    }

    public let id: JointID
    public let bodyA: ObjectID
    public let bodyB: ObjectID?
    public let anchorA: WorldPoint
    public let anchorB: WorldPoint
    /// Używany przez zawias i spaw; dystans go ignoruje.
    public let referenceAngle: Float
    public let kind: Kind
    /// Domyślnie ciała połączone więzem nie kolidują ze sobą, jak w Box2D.
    public let collideConnected: Bool

    public init(id: JointID, bodyA: ObjectID, bodyB: ObjectID? = nil, anchorA: WorldPoint = .zero,
                anchorB: WorldPoint = .zero, referenceAngle: Float = 0, kind: Kind,
                collideConnected: Bool = false) throws {
        try requireFinite(anchorA, "joint.anchorA")
        try requireFinite(anchorB, "joint.anchorB")
        try requireFinite(referenceAngle, "joint.referenceAngle")
        guard bodyA != bodyB else { throw ModelValidationError.valueOutOfRange("joint.bodies") }
        if case .distance(let length, let softness, let damping) = kind {
            try requireNonnegative(length, "joint.length")
            try requireNonnegative(softness, "joint.softness")
            try requireNonnegative(damping, "joint.damping")
        }
        self.id = id; self.bodyA = bodyA; self.bodyB = bodyB
        self.anchorA = anchorA; self.anchorB = anchorB; self.referenceAngle = referenceAngle
        self.kind = kind; self.collideConnected = collideConnected
    }

    public var isDistance: Bool { if case .distance = kind { return true }; return false }
}
