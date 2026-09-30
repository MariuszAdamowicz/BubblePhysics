struct WorldBoundaryConstraint {
    let bounds: AABB

    func project(particles: inout ParticleStore, indices: [Int]) {
        for index in indices {
            var particle = particles[index]
            particle.position.x = min(max(particle.position.x, bounds.minimum.x), bounds.maximum.x)
            particle.position.y = min(max(particle.position.y, bounds.minimum.y), bounds.maximum.y)
            particles[index] = particle
        }
    }
}
