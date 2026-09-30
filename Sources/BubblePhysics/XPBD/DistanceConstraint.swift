struct DistanceConstraint: XPBDConstraint {
    let first: Int
    let second: Int
    let restLength: Float
    let compliance: Float
    private var lambda: Float = 0

    init(first: Int, second: Int, restLength: Float, compliance: Float = 0) {
        self.first = first
        self.second = second
        self.restLength = restLength
        self.compliance = compliance
    }

    mutating func resetMultiplier() {
        lambda = 0
    }

    mutating func project(particles: inout ParticleStore, timeStep: Float) {
        let firstParticle = particles[first]
        let secondParticle = particles[second]
        let separation = secondParticle.position - firstParticle.position
        let distance = length(separation)
        guard distance > 0 else { return }

        let gradient = separation * (1 / distance)
        let alpha = compliance / (timeStep * timeStep)
        let weight = firstParticle.inverseMass + secondParticle.inverseMass
        guard weight + alpha > 0 else { return }

        let deltaLambda = -(distance - restLength + alpha * lambda) / (weight + alpha)
        lambda += deltaLambda
        particles[first].position = firstParticle.position - gradient * (firstParticle.inverseMass * deltaLambda)
        particles[second].position = secondParticle.position + gradient * (secondParticle.inverseMass * deltaLambda)
    }
}
