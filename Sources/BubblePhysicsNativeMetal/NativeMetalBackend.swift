@_exported import BubblePhysicsReference

public struct NativeMetalConfiguration: Equatable, Sendable {
    public var solverIterationCount: Int
    /// Zero oznacza twardy kontakt PBD; wartość dodatnia włącza compliance XPBD.
    public var contactCompliance: Float
    public var cacheExpiryFrames: Int
    public var teleportDistanceMultiplier: Float
    public var ccdVelocityMultiplier: Float

    public init(solverIterationCount: Int = 8, cacheExpiryFrames: Int = 30,
                teleportDistanceMultiplier: Float = 2, ccdVelocityMultiplier: Float = 1,
                contactCompliance: Float = 0) {
        self.solverIterationCount = solverIterationCount
        self.contactCompliance = contactCompliance
        self.cacheExpiryFrames = cacheExpiryFrames
        self.teleportDistanceMultiplier = teleportDistanceMultiplier
        self.ccdVelocityMultiplier = ccdVelocityMultiplier
    }

    public static let `default` = NativeMetalConfiguration()

    public var sanitized: NativeMetalConfiguration {
        var value = self
        value.solverIterationCount = max(1, solverIterationCount)
        value.contactCompliance = contactCompliance.isFinite ? max(0, contactCompliance) : 0
        value.cacheExpiryFrames = max(0, cacheExpiryFrames)
        value.teleportDistanceMultiplier = teleportDistanceMultiplier.isFinite && teleportDistanceMultiplier > 0
            ? teleportDistanceMultiplier : Self.default.teleportDistanceMultiplier
        value.ccdVelocityMultiplier = ccdVelocityMultiplier.isFinite && ccdVelocityMultiplier > 0
            ? ccdVelocityMultiplier : Self.default.ccdVelocityMultiplier
        return value
    }
}

public struct NativeMetalFrameTelemetry: Equatable, Sendable {
    public let backend: ReferenceSimulationBackend
    public let commandBufferCount: Int
    public let encoderCount: Int
    public let cacheHitCount: Int
    public let cacheResetCount: Int
    public let contactCount: Int
    public let solverIterationCount: Int
    public let didEncounterNonFinite: Bool
    public let fallbackReason: String?
    public let gpuMilliseconds: Double

    public init(backend: ReferenceSimulationBackend = .cpu, commandBufferCount: Int = 0,
                encoderCount: Int = 0, cacheHitCount: Int = 0, cacheResetCount: Int = 0,
                contactCount: Int = 0, didEncounterNonFinite: Bool = false,
                fallbackReason: String? = nil, gpuMilliseconds: Double = 0,
                solverIterationCount: Int = 0) {
        self.backend = backend
        self.commandBufferCount = commandBufferCount
        self.encoderCount = encoderCount
        self.cacheHitCount = cacheHitCount
        self.cacheResetCount = cacheResetCount
        self.contactCount = contactCount
        self.solverIterationCount = solverIterationCount
        self.didEncounterNonFinite = didEncounterNonFinite
        self.fallbackReason = fallbackReason
        self.gpuMilliseconds = gpuMilliseconds
    }
}
