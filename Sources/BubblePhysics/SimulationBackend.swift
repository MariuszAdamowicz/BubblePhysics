public enum SimulationBackendKind: Equatable, Sendable {
    case cpu
    case metal
}

public struct SimulationBackendDiagnostics: Equatable, Sendable {
    public let backend: SimulationBackendKind
    public let didFallbackToCPU: Bool
    public let particleCount: Int
    public let candidatePairCount: Int
    public let contactCount: Int
    public let didOverflow: Bool

    public init(
        backend: SimulationBackendKind,
        didFallbackToCPU: Bool,
        particleCount: Int,
        candidatePairCount: Int,
        contactCount: Int,
        didOverflow: Bool
    ) {
        self.backend = backend
        self.didFallbackToCPU = didFallbackToCPU
        self.particleCount = particleCount
        self.candidatePairCount = candidatePairCount
        self.contactCount = contactCount
        self.didOverflow = didOverflow
    }
}

public struct SimulationParticleSnapshot: Equatable, Sendable {
    public let position: Vector2
    public let previousPosition: Vector2
    public let inverseMass: Float

    public init(position: Vector2, previousPosition: Vector2, inverseMass: Float) {
        self.position = position
        self.previousPosition = previousPosition
        self.inverseMass = inverseMass
    }
}

public struct SimulationBubbleSnapshot: Equatable, Sendable {
    public let id: BubbleID
    public let centerIndex: Int
    public let boundaryIndices: [Int]
    public let restArea: Float

    public init(id: BubbleID, centerIndex: Int, boundaryIndices: [Int], restArea: Float) {
        self.id = id
        self.centerIndex = centerIndex
        self.boundaryIndices = boundaryIndices
        self.restArea = restArea
    }
}

public struct SimulationWorldSnapshot: Equatable, Sendable {
    public let particles: [SimulationParticleSnapshot]
    public let bubbles: [SimulationBubbleSnapshot]

    public init(particles: [SimulationParticleSnapshot], bubbles: [SimulationBubbleSnapshot]) {
        self.particles = particles
        self.bubbles = bubbles
    }
}
