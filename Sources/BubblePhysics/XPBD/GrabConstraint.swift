struct GrabConstraint {
    let particleIndex: Int
    let target: Vector2
    let maximumCorrection: Float

    func project(particles: inout ParticleStore) -> Float {
        var particle = particles[particleIndex]
        let delta = target - particle.position
        let distanceToTarget = length(delta)
        guard distanceToTarget > 0 else { return 0 }
        let correction = min(distanceToTarget, maximumCorrection)
        particle.position = particle.position + normalized(delta) * correction
        particles[particleIndex] = particle
        return distanceToTarget - correction
    }
}
