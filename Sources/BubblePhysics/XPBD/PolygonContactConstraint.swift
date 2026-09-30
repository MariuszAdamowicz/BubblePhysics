struct PolygonContactConstraint {
    let particleIndex: Int
    let normal: Vector2
    let penetration: Float
    let surfaceVelocity: Vector2

    func project(particles: inout ParticleStore, timeStep: Float) {
        guard penetration > 0, normal != .zero else { return }
        var particle = particles[particleIndex]
        particle.position = particle.position + normal * penetration
        particle.previousPosition = particle.position - surfaceVelocity * timeStep
        particles[particleIndex] = particle
    }
}
