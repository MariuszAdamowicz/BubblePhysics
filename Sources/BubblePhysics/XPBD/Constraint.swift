import Foundation

protocol XPBDConstraint {
    mutating func project(particles: inout ParticleStore, timeStep: Float)
}

func squaredLength(_ vector: Vector2) -> Float {
    vector.dot(vector)
}

func length(_ vector: Vector2) -> Float {
    sqrt(squaredLength(vector))
}
