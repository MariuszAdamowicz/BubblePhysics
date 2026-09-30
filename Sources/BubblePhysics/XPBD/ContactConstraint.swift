struct ContactConstraint: XPBDConstraint {
    let first: Int
    let second: Int
    let normal: Vector2
    let penetration: Float
    let compliance: Float
    private var lambda: Float = 0

    init(first: Int, second: Int, normal: Vector2, penetration: Float, compliance: Float = 0) {
        self.first = first
        self.second = second
        self.normal = normal
        self.penetration = penetration
        self.compliance = compliance
    }

    mutating func project(particles: inout ParticleStore, timeStep: Float) {
        guard penetration > 0, normal != .zero else { return }
        let firstParticle = particles[first]
        let secondParticle = particles[second]
        let alpha = compliance / (timeStep * timeStep)
        let weight = firstParticle.inverseMass + secondParticle.inverseMass
        guard weight + alpha > 0 else { return }
        let deltaLambda = -(-penetration + alpha * lambda) / (weight + alpha)
        lambda += deltaLambda
        particles[first].position = firstParticle.position + normal * (firstParticle.inverseMass * deltaLambda)
        particles[second].position = secondParticle.position - normal * (secondParticle.inverseMass * deltaLambda)
    }
}
