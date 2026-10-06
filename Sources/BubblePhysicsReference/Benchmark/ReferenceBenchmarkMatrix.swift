import Foundation

public struct ReferenceBenchmarkMatrixConfiguration: Sendable, Equatable {
    public var scene: ReferenceConvergenceScene
    public var seed: UInt64
    public var broadPhase: ReferenceBroadPhaseSelection
    public var warmupSteps: Int
    public var measuredSteps: Int
    public var iterationLimits: [Int]
    public var backend: ReferenceSimulationBackend
    public var gpuDiagnosticsEnabled: Bool

    public init(
        scene: ReferenceConvergenceScene,
        seed: UInt64 = 0x2B_60_F5,
        broadPhase: ReferenceBroadPhaseSelection = .sweepAndPrune,
        warmupSteps: Int,
        measuredSteps: Int,
        iterationLimits: [Int] = [4, 8, 12, 16],
        backend: ReferenceSimulationBackend = .cpu,
        gpuDiagnosticsEnabled: Bool = false
    ) {
        self.scene = scene
        self.seed = seed
        self.broadPhase = broadPhase
        self.warmupSteps = max(0, warmupSteps)
        self.measuredSteps = max(0, measuredSteps)
        self.iterationLimits = iterationLimits.map { max(1, $0) }
        self.backend = backend
        self.gpuDiagnosticsEnabled = gpuDiagnosticsEnabled
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
            "limit full_p50_ms full_p95_ms full_max_ms solver_p95_ms contour_p95_ms render_p95_ms penetration_p95 penetration_max residual_p95 residual_max unconverged_components containment non_finite backend cpu_frames metal_frames fallbacks warmup_fallbacks gpu_measurement",
        ]
        if configuration.backend == .metal {
            lines.insert("gpu_diagnostics=\(configuration.gpuDiagnosticsEnabled ? "enabled" : "disabled"); diagnostyka dodaje narzut hosta — nie mieszaj jej z pomiarem akceptacyjnym. Etapy obejmują całe command buffery; newton zawiera inicjalizację PCG, geometry inicjalizację klatki, ccd rozpoczęcie solve i finalizację świata.", at: 6)
            lines.insert("Uwaga GPU: solver_p95_ms obejmuje cały command buffer GPU (sumę etapów) albo solver CPU przy fallbacku; contour_p95_ms mierzy pobranie/pakowanie konturów na hoście. Osobny gpu_completed zawiera wyłącznie ukończone klatki Metal; czasy tabeli przy fallbackach są mieszane i nie kwalifikują GPU.", at: 6)
        }
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
                run.backend.rawValue,
                "\(run.cpuFrameCount)",
                "\(run.metalFrameCount)",
                "\(run.fallbackCount)",
                "\(run.warmupFallbackCount)",
                run.isGPUAcceptanceMeasurementEligible ? "eligible" : (run.backend == .cpu ? "not_applicable" : "ineligible"),
            ].joined(separator: " "))
        }
        for run in runs where !run.fallbackReasons.isEmpty {
            for reason in run.fallbackReasons.keys.sorted() {
                lines.append("fallback_reason limit=\(run.newtonIterationLimit) count=\(run.fallbackReasons[reason]!) reason=\(singleLine(reason))")
            }
        }
        for run in runs where configuration.backend == .metal {
            let limit = run.newtonIterationLimit
            let gpu = run.completedMetalTiming
            let cpu = run.cpuFallbackFullFrameTiming
            func gpuTime(_ value: Double) -> String { run.completedMetalSampleCount > 0 ? format(value) : "unavailable" }
            func cpuTime(_ value: Double) -> String { run.cpuFallbackSampleCount > 0 ? format(value) : "unavailable" }
            lines.append("gpu_completed limit=\(limit) measured_frames=\(run.completedMetalSampleCount) command_buffers_p50_ms=\(gpuTime(gpu.p50Milliseconds)) command_buffers_p95_ms=\(gpuTime(gpu.p95Milliseconds)) command_buffers_max_ms=\(gpuTime(gpu.maximumMilliseconds))")
            if configuration.gpuDiagnosticsEnabled {
                func fields(_ label: String, _ summary: ReferenceTimingSummary, count: Int, unit: String = "") -> String {
                    func value(_ value: Double) -> String { count > 0 ? format(value) : "unavailable" }
                    let prefix = label.isEmpty ? "" : label + "_"
                    return "\(prefix)p50\(unit)=\(value(summary.p50Milliseconds)) \(prefix)p95\(unit)=\(value(summary.p95Milliseconds)) \(prefix)max\(unit)=\(value(summary.maximumMilliseconds))"
                }
                let count = run.gpuProfileSampleCount
                lines.append("gpu_profile limit=\(limit) measured_frames=\(count) " + [
                    fields("command_buffers", run.gpuProfileCommandBuffers, count: count),
                    fields("encoders", run.gpuProfileEncoders, count: count),
                    fields("host_encoding", run.gpuProfileHostEncoding, count: count, unit: "_ms"),
                    fields("host_waiting", run.gpuProfileHostWaiting, count: count, unit: "_ms"),
                    fields("host_readback", run.gpuProfileHostReadback, count: count, unit: "_ms")
                ].joined(separator: " "))
                for stage in ReferenceBenchmarkGPUFrameProfile.stages {
                    let samples = run.gpuProfileStageSampleCounts[stage] ?? 0
                    lines.append("gpu_stage limit=\(limit) stage=\(stage) measured_frames=\(samples) " +
                        fields("", run.gpuProfileStages[stage] ?? .init(values: []), count: samples, unit: "_ms"))
                }
            }
            lines.append("cpu_fallback limit=\(limit) measured_frames=\(run.cpuFallbackSampleCount) full_p50_ms=\(cpuTime(cpu.p50Milliseconds)) full_p95_ms=\(cpuTime(cpu.p95Milliseconds)) full_max_ms=\(cpuTime(cpu.maximumMilliseconds))")
            lines.append("gpu_work limit=\(limit) scope=completed_measured_frames solve_calls_max=\(optionalCount(run.maximumGPUSolveCalls)) tentative_solve_calls_max=\(optionalCount(run.maximumGPUTentativeSolveCalls)) contacts_max=\(optionalCount(run.maximumGPUContacts)) ccd_groups_max=\(optionalCount(run.maximumGPUCCDGroups))")
            for (label, failure) in [("gpu_first_failure", run.firstGPUFailure), ("gpu_fatal_failure", run.firstFatalGPUFailure)] {
                if let failure {
                    lines.append("\(label) limit=\(limit) stage=\(singleLine(failure.stage)) step=\(failure.scenarioStep) classification=\(singleLine(failure.classification)) reason=\(singleLine(failure.reason))")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func optionalCount(_ value: Int?) -> String { value.map(String.init) ?? "unavailable" }

    private func singleLine(_ value: String) -> String {
        // Driver text must not inject rows or terminal controls into copied data.
        value.components(separatedBy: .controlCharacters.union(.newlines)).joined(separator: " ")
    }

    private func format(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
    }
}

public enum ReferenceBenchmarkMatrixRunner {
    public typealias Run = @Sendable (
        _ scenario: ReferenceConvergenceScenario,
        _ warmupSteps: Int,
        _ measuredSteps: Int,
        _ progress: @escaping @Sendable (Int, Int) async -> Void
    ) async throws -> ReferenceBenchmarkReport

    public static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in }
    ) async throws -> ReferenceBenchmarkMatrixReport {
        guard configuration.backend == .cpu else { throw ReferenceBenchmarkError.backendRequiresFrameExecutor }
        return try await measure(
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

    public static func measure(
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
