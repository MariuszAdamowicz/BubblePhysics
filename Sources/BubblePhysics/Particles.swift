public struct Particle: Equatable, Sendable {
    public var position: Vector2
    public var previousPosition: Vector2
    public var inverseMass: Float

    public init(position: Vector2, inverseMass: Float = 1) {
        self.position = position
        previousPosition = position
        self.inverseMass = inverseMass
    }
}

public struct ParticleStore: Sendable {
    public private(set) var particles: [Particle] = []

    public init() {}

    @discardableResult
    public mutating func append(_ particle: Particle) -> Int {
        particles.append(particle)
        return particles.count - 1
    }
}
