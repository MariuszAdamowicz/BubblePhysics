import Foundation

public struct ReferenceBenchmarkMatrixConfiguration: Sendable, Equatable {
    public var scene: ReferenceConvergenceScene
    public var seed: UInt64
    public var broadPhase: ReferenceBroadPhaseSelection
    public var warmupSteps: Int
    public var measuredSteps: Int
    public var iterationLimits: [Int]

    public init(
        scene: ReferenceConvergenceScene,
        seed: UInt64 = 0x2B_60_F5,
        broadPhase: ReferenceBroadPhaseSelection = .sweepAndPrune,
        warmupSteps: Int,
        measuredSteps: Int,
        iterationLimits: [Int] = [4, 8, 12, 16]
    ) {
        self.scene = scene
        self.seed = seed
        self.broadPhase = broadPhase
        self.warmupSteps = max(0, warmupSteps)
        self.measuredSteps = max(0, measuredSteps)
        self.iterationLimits = iterationLimits.map { max(1, $0) }
    }
}

public struct ReferenceBenchmarkProgress: Sendable, Equatable {
    public var variantIndex: Int
    public var iterationLimit: Int
    public var completedSteps: Int
    public var totalSteps: Int
}

public struct ReferenceBenchmarkMatrixReport: Sendable, Equatable {
    public var configuration: ReferenceBenchmarkMatrixConfiguration
    public var runs: [ReferenceBenchmarkReport]

    public func plainText(deviceName: String, systemVersion: String) -> String {
        var lines = [
            "BubblePhysics reference convergence benchmark",
            "device: \(deviceName)",
            "system: \(systemVersion)",
            "scene: \(configuration.scene.rawValue)",
            "seed: \(configuration.seed)",
            "warmup: \(configuration.warmupSteps) measured: \(configuration.measuredSteps)",
            "limit full_p50_ms full_p95_ms full_max_ms solver_p95_ms contour_p95_ms render_p95_ms penetration_p95 penetration_max residual_p95 residual_max unconverged_components containment non_finite",
        ]
        for run in runs {
            lines.append([
                "\(run.newtonIterationLimit)",
                format(run.fullFrame.p50Milliseconds),
                format(run.fullFrame.p95Milliseconds),
                format(run.fullFrame.maximumMilliseconds),
                format(run.solver.p95Milliseconds),
                format(run.contour.p95Milliseconds),
                format(run.renderPreparation.p95Milliseconds),
                format(run.penetration.p95),
                format(run.penetration.maximum),
                format(run.finalResidual.p95),
                format(run.finalResidual.maximum),
                "\(run.maximumUnconvergedContactComponents)",
                "\(run.maximumConsecutiveContainmentFrames)",
                run.hasNonFiniteState ? "yes" : "no",
            ].joined(separator: " "))
        }
        return lines.joined(separator: "\n")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public enum ReferenceBenchmarkMatrixRunner {
    typealias Run = @Sendable (
        _ scenario: ReferenceConvergenceScenario,
        _ warmupSteps: Int,
        _ measuredSteps: Int,
        _ progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> ReferenceBenchmarkReport

    public static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in }
    ) async throws -> ReferenceBenchmarkMatrixReport {
        try await measure(
            configuration: configuration,
            progress: progress,
            run: { scenario, warmup, measured, localProgress in
                try await ReferenceBenchmarkRunner.measureAsync(
                    scenario: scenario,
                    warmupSteps: warmup,
                    measuredSteps: measured,
                    progress: localProgress
                )
            }
        )
    }

    static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void,
        run: @escaping Run
    ) async throws -> ReferenceBenchmarkMatrixReport {
        let stepsPerVariant = configuration.warmupSteps + configuration.measuredSteps
        let totalSteps = stepsPerVariant * configuration.iterationLimits.count
        var reports: [ReferenceBenchmarkReport] = []
        reports.reserveCapacity(configuration.iterationLimits.count)

        for (variantIndex, limit) in configuration.iterationLimits.enumerated() {
            try Task.checkCancellation()
            let scenario = ReferenceConvergenceScenario(
                scene: configuration.scene,
                seed: configuration.seed,
                newtonIterationLimit: limit,
                broadPhase: configuration.broadPhase
            )
            let base = variantIndex * stepsPerVariant
            let report = try await run(
                scenario,
                configuration.warmupSteps,
                configuration.measuredSteps
            ) { localCompleted, _ in
                await progress(.init(
                    variantIndex: variantIndex,
                    iterationLimit: limit,
                    completedSteps: base + localCompleted,
                    totalSteps: totalSteps
                ))
            }
            try Task.checkCancellation()
            reports.append(report)
        }
        return .init(configuration: configuration, runs: reports)
    }
}
