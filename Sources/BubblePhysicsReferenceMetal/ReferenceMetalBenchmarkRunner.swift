import BubblePhysicsReference

/// iOS runtime selection uses ReferenceMetalWorldRunner's iOS-only initializer.
/// On other platforms a requested Metal frame is explicitly a CPU fallback.
@MainActor
public enum ReferenceMetalBenchmarkRunner {
    public static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in }
    ) async throws -> ReferenceBenchmarkMatrixReport {
        try await measure(configuration: configuration, progress: progress,
                          makeRunner: { ReferenceMetalWorldRunner(backend: configuration.backend) })
    }

    // Real host pipeline injection is internal; it does not enable macOS runtime.
    static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in },
        makeRunner: @escaping @MainActor () throws -> ReferenceMetalWorldRunner
    ) async throws -> ReferenceBenchmarkMatrixReport {
        if configuration.backend == .cpu {
            return try await ReferenceBenchmarkMatrixRunner.measure(configuration: configuration, progress: progress)
        }
        return try await ReferenceBenchmarkMatrixRunner.measure(configuration: configuration, progress: progress,
            run: { scenario, warmup, measured, localProgress in
                let runner = try await makeRunner()
                return try await ReferenceBenchmarkRunner.measureAsync(
                    scenario: scenario, warmupSteps: warmup, measuredSteps: measured,
                    backend: configuration.backend,
                    frameExecutor: { world, scenario, step in
                        await runner.benchmarkFrame(world: &world, scenario: scenario, step: step)
                    }, progress: localProgress)
            })
    }
}

extension ReferenceMetalWorldRunner {
    fileprivate func benchmarkFrame(
        world: inout ReferenceWorld, scenario: ReferenceConvergenceScenario, step: Int
    ) async -> ReferenceBenchmarkFrameResult {
        let clock = ContinuousClock()
        let fullStart = clock.now
        scenario.updatePolygon(in: &world, fromStep: step, toStep: step + 1)
        let simulationStart = clock.now
        let report = await self.step(world: &world, scenarioStep: step)
        let simulationEnd = clock.now
        // GPU contours are already cached by atomic world publication. A CPU
        // fallback generates them here, exactly as the CPU benchmark does.
        let contourStart = clock.now
        let geometry = world.bubbles.map { ($0, world.contour(for: $0.id)) }
        let contourEnd = clock.now
        let prepared = geometry.map { bubble, contour in
            ReferencePreparedBubble(id: bubble.id, center: bubble.center, rotation: bubble.rotation, contour: contour)
        }
        let end = clock.now
        return .init(worldReport: report,
            simulationMilliseconds: Self.benchmarkMilliseconds(simulationStart.duration(to: simulationEnd)),
            contourMilliseconds: Self.benchmarkMilliseconds(contourStart.duration(to: contourEnd)),
            renderPreparationMilliseconds: Self.benchmarkMilliseconds(contourEnd.duration(to: end)),
            fullFrameMilliseconds: Self.benchmarkMilliseconds(fullStart.duration(to: end)),
            contourPointCount: prepared.reduce(0) { $0 + $1.contour.count }, preparedBubbles: prepared,
            backend: telemetry.backend, fallbackReason: telemetry.fallbackReason)
    }

    private static func benchmarkMilliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
