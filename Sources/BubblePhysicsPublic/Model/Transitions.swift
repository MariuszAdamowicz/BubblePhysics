import Foundation

public enum PhysicsParameter: Hashable, Sendable {
    case deformability, damping, friction, restitution
}

public enum TransitionTarget: Hashable, Sendable {
    case physicsMaterial(PhysicsMaterialID, PhysicsParameter)
    case globalForce
    case renderStyle(RenderStyleID, ParameterID)
    case objectPresentation(ObjectID, ParameterID)
    case bubbleRadius(ObjectID)
}

public enum TransitionValue: Equatable, Sendable {
    case scalar(Float)
    case vector(WorldPoint)
}

public enum TransitionCurve: Equatable, Sendable, Codable {
    case linear, easeIn, easeOut, easeInOut
    /// Punkty kontrolne w przestrzeni [0, 1]; x1 <= x2 zapewnia monotoniczny czas.
    case cubicBezier(x1: Float, y1: Float, x2: Float, y2: Float)
}

/// Walidacja celu i wartości odbywa się atomowo wraz z całą transakcją.
public struct ParameterTransition: Equatable, Sendable {
    public let target: TransitionTarget
    public let value: TransitionValue
    public let duration: TimeInterval
    public let curve: TransitionCurve
    public init(target: TransitionTarget, value: TransitionValue, duration: TimeInterval,
                curve: TransitionCurve = .linear) {
        self.target = target; self.value = value; self.duration = duration; self.curve = curve
    }
}
