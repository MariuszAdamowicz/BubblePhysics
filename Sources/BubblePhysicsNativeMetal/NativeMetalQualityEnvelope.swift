import BubblePhysicsReference

/// Evidence from a convergence run and the controlled dynamic acceptance scenes.
/// Radius fractions are dimensionless; hashes compare two runs of this backend,
/// not CPU coordinates with GPU coordinates.
public struct NativeMetalQualitySample: Equatable, Sendable {
    public var penetrationP95: Double
    public var penetrationMaximum: Double
    public var containment: Int
    public var hasNonFiniteState: Bool
    public var maximumRestDisplacementRadiusFraction: Double?
    public var releasedContourMeanRadiusErrorFraction: Double?
    public var contourOscillationGrows: Bool?
    public var publishedStateHash: UInt64?
    public var repeatedPublishedStateHash: UInt64?

    public init(penetrationP95: Double, penetrationMaximum: Double, containment: Int,
                hasNonFiniteState: Bool, maximumRestDisplacementRadiusFraction: Double? = nil,
                releasedContourMeanRadiusErrorFraction: Double? = nil, contourOscillationGrows: Bool? = nil,
                publishedStateHash: UInt64? = nil, repeatedPublishedStateHash: UInt64? = nil) {
        self.penetrationP95 = penetrationP95
        self.penetrationMaximum = penetrationMaximum
        self.containment = containment
        self.hasNonFiniteState = hasNonFiniteState
        self.maximumRestDisplacementRadiusFraction = maximumRestDisplacementRadiusFraction
        self.releasedContourMeanRadiusErrorFraction = releasedContourMeanRadiusErrorFraction
        self.contourOscillationGrows = contourOscillationGrows
        self.publishedStateHash = publishedStateHash
        self.repeatedPublishedStateHash = repeatedPublishedStateHash
    }

    public init(report: ReferenceBenchmarkReport) {
        self.init(penetrationP95: report.penetration.p95, penetrationMaximum: report.penetration.maximum,
                  containment: report.maximumConsecutiveContainmentFrames, hasNonFiniteState: report.hasNonFiniteState)
    }
}

public enum NativeMetalQualityViolation: String, Equatable, Sendable {
    case containment, nonFinite, penetrationP95, penetrationMaximum
    case restJitter, contourReturn, contourOscillation, repeatability, missingEvidence
}

public enum NativeMetalQualityEnvelope {
    /// Implements the approved quality envelope. Timing/device qualification is
    /// deliberately separate; missing controlled-scene evidence cannot pass.
    public static func evaluate(cpu: NativeMetalQualitySample, gpu: NativeMetalQualitySample) -> [NativeMetalQualityViolation] {
        var violations: [NativeMetalQualityViolation] = []
        if gpu.containment != 0 { violations.append(.containment) }
        let finite = [cpu.penetrationP95, cpu.penetrationMaximum, gpu.penetrationP95, gpu.penetrationMaximum]
            + [gpu.maximumRestDisplacementRadiusFraction, gpu.releasedContourMeanRadiusErrorFraction].compactMap { $0 }
        if cpu.hasNonFiniteState || gpu.hasNonFiniteState || finite.contains(where: { !$0.isFinite || $0 < 0 }) {
            violations.append(.nonFinite)
        }
        if gpu.penetrationP95 > max(cpu.penetrationP95 * 1.10, cpu.penetrationP95 + 0.5) {
            violations.append(.penetrationP95)
        }
        if gpu.penetrationMaximum > max(cpu.penetrationMaximum * 1.15, cpu.penetrationMaximum + 1.0) {
            violations.append(.penetrationMaximum)
        }
        if let jitter = gpu.maximumRestDisplacementRadiusFraction, jitter >= 0.001 { violations.append(.restJitter) }
        if let error = gpu.releasedContourMeanRadiusErrorFraction, error >= 0.02 { violations.append(.contourReturn) }
        if gpu.contourOscillationGrows == true { violations.append(.contourOscillation) }
        if let hash = gpu.publishedStateHash, let repeated = gpu.repeatedPublishedStateHash, hash != repeated {
            violations.append(.repeatability)
        }
        if gpu.maximumRestDisplacementRadiusFraction == nil || gpu.releasedContourMeanRadiusErrorFraction == nil
            || gpu.contourOscillationGrows == nil || gpu.publishedStateHash == nil || gpu.repeatedPublishedStateHash == nil {
            violations.append(.missingEvidence)
        }
        return violations
    }
}
