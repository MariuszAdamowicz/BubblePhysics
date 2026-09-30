struct AreaConstraint: XPBDConstraint {
    let indices: [Int]
    let restArea: Float
    let compliance: Float
    private var lambda: Float = 0

    init(indices: [Int], restArea: Float, compliance: Float = 0) {
        self.indices = indices
        self.restArea = restArea
        self.compliance = compliance
    }

    mutating func resetMultiplier() {
        lambda = 0
    }

    mutating func project(particles: inout ParticleStore, timeStep: Float) {
        guard indices.count >= 3 else { return }
        var area: Float = 0
        var gradients = Array(repeating: Vector2.zero, count: indices.count)
        for offset in indices.indices {
            let previous = particles[indices[(offset + indices.count - 1) % indices.count]].position
            let current = particles[indices[offset]].position
            let next = particles[indices[(offset + 1) % indices.count]].position
            area += current.x * next.y - current.y * next.x
            gradients[offset] = Vector2(x: (next.y - previous.y) * 0.5, y: (previous.x - next.x) * 0.5)
        }
        area *= 0.5

        let alpha = compliance / (timeStep * timeStep)
        let weight = zip(indices, gradients).reduce(Float.zero) { partial, item in
            partial + particles[item.0].inverseMass * squaredLength(item.1)
        }
        guard weight + alpha > 0 else { return }
        let deltaLambda = -(area - restArea + alpha * lambda) / (weight + alpha)
        lambda += deltaLambda
        for (index, gradient) in zip(indices, gradients) {
            let particle = particles[index]
            particles[index].position = particle.position + gradient * (particle.inverseMass * deltaLambda)
        }
    }
}
