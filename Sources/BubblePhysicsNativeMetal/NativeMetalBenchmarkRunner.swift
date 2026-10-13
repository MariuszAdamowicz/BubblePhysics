import Foundation
import BubblePhysicsReference

/// Reuses the reference scenes, matrix and full-frame measurement boundary.
@MainActor
public enum NativeMetalBenchmarkRunner {
    public static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in }
    ) async throws -> ReferenceBenchmarkMatrixReport {
        try await measure(configuration: configuration, progress: progress, makeRunner: { limit in
            NativeMetalWorldRunner(configuration: .init(solverIterationCount: limit))
                ?? NativeMetalWorldRunner(executor: nil, configuration: .init(solverIterationCount: limit))
        })
    }

    static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in },
        makeRunner: @escaping @MainActor (Int) throws -> NativeMetalWorldRunner
    ) async throws -> ReferenceBenchmarkMatrixReport {
        guard configuration.backend == .nativeMetal else { throw ReferenceBenchmarkError.backendRequiresFrameExecutor }
        return try await ReferenceBenchmarkMatrixRunner.measure(configuration: configuration, progress: progress,
            run: { scenario, warmup, measured, localProgress in
                let runner = try await makeRunner(scenario.newtonIterationLimit)
                return try await ReferenceBenchmarkRunner.measureAsync(scenario: scenario,
                    warmupSteps: warmup, measuredSteps: measured, backend: .nativeMetal,
                    frameExecutor: { world, scenario, step in
                        await runner.benchmarkFrame(world: &world, scenario: scenario, step: step)
                    }, progress: localProgress)
            })
    }
}

extension NativeMetalWorldRunner {
    fileprivate func benchmarkFrame(world: inout ReferenceWorld, scenario: ReferenceConvergenceScenario,
                                step: Int) async -> ReferenceBenchmarkFrameResult {
        let clock = ContinuousClock()
        let start = clock.now
        scenario.updatePolygon(in: &world, fromStep: step, toStep: step + 1)
        let simulationStart = clock.now
        var report = await self.step(world: &world, scenarioStep: step)
        report.hasNonFiniteState = report.hasNonFiniteState || telemetry.didEncounterNonFinite
        let simulationEnd = clock.now
        let geometry = world.bubbles.map { ($0, world.contour(for: $0.id)) }
        let contourEnd = clock.now
        let prepared = geometry.map { bubble, contour in
            ReferencePreparedBubble(id: bubble.id, center: bubble.center, rotation: bubble.rotation, contour: contour)
        }
        let end = clock.now
        let succeeded = telemetry.backend == .nativeMetal && telemetry.fallbackReason == nil
        if succeeded { report.solverMilliseconds = telemetry.gpuMilliseconds }
        let neutralProfile = ReferenceBenchmarkGPUFrameProfile(commandBufferCount: profile.commandBufferCount,
            encoderCount: profile.encoderCount, stageGPUMilliseconds: profile.stageGPUMilliseconds,
            hostEncodingMilliseconds: profile.hostEncodingMilliseconds,
            hostWaitingMilliseconds: profile.hostWaitingMilliseconds, hostReadbackMilliseconds: 0)
        return .init(worldReport: report,
            simulationMilliseconds: Self.milliseconds(simulationStart.duration(to: simulationEnd)),
            contourMilliseconds: Self.milliseconds(simulationEnd.duration(to: contourEnd)),
            renderPreparationMilliseconds: Self.milliseconds(contourEnd.duration(to: end)),
            fullFrameMilliseconds: Self.milliseconds(start.duration(to: end)),
            contourPointCount: prepared.reduce(0) { $0 + $1.contour.count }, preparedBubbles: prepared,
            backend: telemetry.backend, fallbackReason: telemetry.fallbackReason,
            gpuTelemetry: .init(completedCommandBuffersMilliseconds: succeeded ? telemetry.gpuMilliseconds : nil,
                contactCount: telemetry.contactCount, profile: succeeded ? neutralProfile : nil,
                native: succeeded ? .init(cacheHits: telemetry.cacheHitCount, cacheResets: telemetry.cacheResetCount,
                    solverIterations: telemetry.solverIterationCount, ccdCandidates: telemetry.ccdCandidateCount) : nil))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
