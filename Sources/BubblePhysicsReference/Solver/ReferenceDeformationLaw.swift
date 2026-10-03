public struct ReferenceContactStress: Sendable, Equatable {
    public var compressionA: Float
    public var compressionB: Float
    public var pressure: Float
    public var effectiveStiffness: Float

    public init(compressionA: Float, compressionB: Float, pressure: Float, effectiveStiffness: Float) {
        self.compressionA = compressionA
        self.compressionB = compressionB
        self.pressure = pressure
        self.effectiveStiffness = effectiveStiffness
    }

    public static let zero = ReferenceContactStress(
        compressionA: 0, compressionB: 0, pressure: 0, effectiveStiffness: 0
    )
}

public enum ReferenceDeformationLaw {
    public static func solve(
        requiredCompression: Float,
        radiusA: Float,
        stiffnessA: Float,
        radiusB: Float,
        stiffnessB: Float,
        nonlinearStiffening: Float
    ) -> ReferenceContactStress {
        let required = finiteNonnegative(requiredCompression)
        guard required > 0 else { return .zero }

        var lower: Float = 0
        var upper = required
        for _ in 0..<32 {
            let compressionA = (lower + upper) * 0.5
            let compressionB = required - compressionA
            if pressure(compressionA, radius: radiusA, stiffness: stiffnessA, alpha: nonlinearStiffening)
                < pressure(compressionB, radius: radiusB, stiffness: stiffnessB, alpha: nonlinearStiffening) {
                lower = compressionA
            } else {
                upper = compressionA
            }
        }

        let compressionA = (lower + upper) * 0.5
        let compressionB = required - compressionA
        let tangentA = tangent(compressionA, radius: radiusA, stiffness: stiffnessA, alpha: nonlinearStiffening)
        let tangentB = tangent(compressionB, radius: radiusB, stiffness: stiffnessB, alpha: nonlinearStiffening)
        let denominator = tangentA + tangentB
        let effective = denominator > 0 ? tangentA * tangentB / denominator : 0
        return ReferenceContactStress(
            compressionA: compressionA,
            compressionB: compressionB,
            pressure: pressure(compressionA, radius: radiusA, stiffness: stiffnessA, alpha: nonlinearStiffening),
            effectiveStiffness: effective
        )
    }

    public static func solve(
        requiredCompression: Float,
        radiusA: Float,
        stiffnessA: Float,
        nonlinearStiffening: Float
    ) -> ReferenceContactStress {
        let compression = finiteNonnegative(requiredCompression)
        guard compression > 0 else { return .zero }
        return ReferenceContactStress(
            compressionA: compression,
            compressionB: 0,
            pressure: pressure(compression, radius: radiusA, stiffness: stiffnessA, alpha: nonlinearStiffening),
            effectiveStiffness: tangent(compression, radius: radiusA, stiffness: stiffnessA, alpha: nonlinearStiffening)
        )
    }

    private static func pressure(_ compression: Float, radius: Float, stiffness: Float, alpha: Float) -> Float {
        let safeRadius = max(abs(radius), Float.ulpOfOne.squareRoot())
        let safeStiffness = finiteNonnegative(stiffness)
        let safeAlpha = finiteNonnegative(alpha)
        let ratio = compression / safeRadius
        let result = safeStiffness * compression * (1 + safeAlpha * ratio * ratio)
        return result.isFinite ? result : Float.greatestFiniteMagnitude
    }

    private static func tangent(_ compression: Float, radius: Float, stiffness: Float, alpha: Float) -> Float {
        let safeRadius = max(abs(radius), Float.ulpOfOne.squareRoot())
        let safeStiffness = finiteNonnegative(stiffness)
        let safeAlpha = finiteNonnegative(alpha)
        let ratio = compression / safeRadius
        let result = safeStiffness * (1 + 3 * safeAlpha * ratio * ratio)
        return result.isFinite ? result : Float.greatestFiniteMagnitude
    }

    private static func finiteNonnegative(_ value: Float) -> Float {
        value.isFinite ? max(0, value) : 0
    }
}
