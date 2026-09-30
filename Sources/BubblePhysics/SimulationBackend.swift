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

public struct SimulationDistanceConstraintSnapshot: Equatable, Sendable {
    public let firstIndex: Int
    public let secondIndex: Int
    public let restLength: Float
    public let compliance: Float

    public init(firstIndex: Int, secondIndex: Int, restLength: Float, compliance: Float) {
        self.firstIndex = firstIndex
        self.secondIndex = secondIndex
        self.restLength = restLength
        self.compliance = compliance
    }
}

public struct SimulationAreaConstraintSnapshot: Equatable, Sendable {
    public let boundaryIndices: [Int]
    public let restArea: Float
    public let compliance: Float

    public init(boundaryIndices: [Int], restArea: Float, compliance: Float) {
        self.boundaryIndices = boundaryIndices
        self.restArea = restArea
        self.compliance = compliance
    }
}

public struct SimulationPolygonSnapshot: Equatable, Sendable {
    public let id: PolygonID
    public let mode: RigidPolygonMode
    public let worldVertices: [Vector2]
    public let position: Vector2
    public let linearVelocity: Vector2
    public let angularVelocity: Float
}

public struct SimulationGrabSnapshot: Equatable, Sendable {
    public let id: GrabID
    public let bubbleID: BubbleID
    public let target: Vector2
    public let resistance: Float
}

public struct SimulationWorldSnapshot: Equatable, Sendable {
    public let particles: [SimulationParticleSnapshot]
    public let bubbles: [SimulationBubbleSnapshot]
    public let distanceConstraints: [SimulationDistanceConstraintSnapshot]
    public let areaConstraints: [SimulationAreaConstraintSnapshot]
    public let configuration: WorldConfiguration
    public let bounds: AABB?
    public let polygons: [SimulationPolygonSnapshot]
    public let grabs: [SimulationGrabSnapshot]

    public init(
        particles: [SimulationParticleSnapshot],
        bubbles: [SimulationBubbleSnapshot],
        distanceConstraints: [SimulationDistanceConstraintSnapshot] = [],
        areaConstraints: [SimulationAreaConstraintSnapshot] = [],
        configuration: WorldConfiguration = .default,
        bounds: AABB? = nil,
        polygons: [SimulationPolygonSnapshot] = [],
        grabs: [SimulationGrabSnapshot] = []
    ) {
        self.particles = particles
        self.bubbles = bubbles
        self.distanceConstraints = distanceConstraints
        self.areaConstraints = areaConstraints
        self.configuration = configuration
        self.bounds = bounds
        self.polygons = polygons
        self.grabs = grabs
    }
}
