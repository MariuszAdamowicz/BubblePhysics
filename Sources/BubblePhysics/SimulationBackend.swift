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
