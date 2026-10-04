public enum ReferenceSimulationBackend: Equatable, Sendable {
    case cpu
    case metal
}

public struct ReferenceMetalFrameTelemetry: Equatable, Sendable {
    public let backend: ReferenceSimulationBackend
    public let frameMilliseconds: Double
    public let gpuMilliseconds: Double
    public let finalResidual: Float
    public let newtonIterations: Int
    public let pcgIterations: Int
    public let didOverflow: Bool
    public let didEncounterNonFinite: Bool
    public let fallbackReason: String?

    public init(
        backend: ReferenceSimulationBackend = .cpu,
        frameMilliseconds: Double = 0,
        gpuMilliseconds: Double = 0,
        finalResidual: Float = 0,
        newtonIterations: Int = 0,
        pcgIterations: Int = 0,
        didOverflow: Bool = false,
        didEncounterNonFinite: Bool = false,
        fallbackReason: String? = nil
    ) {
        self.backend = backend
        self.frameMilliseconds = frameMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
        self.finalResidual = finalResidual
        self.newtonIterations = newtonIterations
        self.pcgIterations = pcgIterations
        self.didOverflow = didOverflow
        self.didEncounterNonFinite = didEncounterNonFinite
        self.fallbackReason = fallbackReason
    }
}
