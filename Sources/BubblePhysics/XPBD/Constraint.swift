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

func normalized(_ vector: Vector2) -> Vector2 {
    let magnitude = length(vector)
    return magnitude > 0 ? vector * (1 / magnitude) : .zero
}
