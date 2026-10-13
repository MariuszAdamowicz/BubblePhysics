import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalBenchmarkTests: XCTestCase {
    // Catches a CLI-facing report that silently omits actual controlled GPU
    // measurements, the same-input CPU baseline, or the evaluator verdict.
    func testNativeHarnessCollectsAndPublishesQualityEnvelopeEvidence() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: configuration())
        let run = try XCTUnwrap(matrix.runs.first)
        let sample = NativeMetalQualitySample(report: run)
        XCTAssertNotNil(sample.maximumRestDisplacementRadiusFraction)
        XCTAssertNotNil(sample.releasedContourMeanRadiusErrorFraction)
        XCTAssertNotNil(sample.contourOscillationGrows)
        XCTAssertNotNil(sample.publishedStateHash)
        XCTAssertEqual(sample.publishedStateHash, sample.repeatedPublishedStateHash)
        XCTAssertLessThan(try XCTUnwrap(sample.maximumRestDisplacementRadiusFraction), 0.001)
        XCTAssertLessThan(try XCTUnwrap(sample.releasedContourMeanRadiusErrorFraction), 0.02)
        XCTAssertEqual(sample.contourOscillationGrows, false)
        let cpu = try await ReferenceBenchmarkRunner.measureAsync(scenario: .init(scene: .interactive24,
            seed: matrix.configuration.seed, newtonIterationLimit: 4), warmupSteps: 1, measuredSteps: 2)
        XCTAssertEqual(run.nativeQuality?.cpuPenetrationP95, cpu.penetration.p95)
        XCTAssertEqual(run.nativeQuality?.cpuPenetrationMaximum, cpu.penetration.maximum)
        XCTAssertGreaterThan(try XCTUnwrap(run.nativeQuality?.loadedContourMeanRadiusErrorFraction), 0.02)
        let text = matrix.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("native_quality_envelope=pass"))
        XCTAssertTrue(text.contains("cpu_baseline_measured_frames=2"))
        XCTAssertTrue(text.contains("rest_settle_frames=120 rest_measured_frames=30"))
        XCTAssertTrue(text.contains("released_contour_frames=30"))
        XCTAssertTrue(text.contains("repeat_measured_frames=2"))
    }

    // CPU fallback is not GPU evidence even if its state is finite and stable.
    func testUnavailableNativeQualityEvidenceFailsThePrintedEnvelope() async throws {
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: configuration(),
            makeRunner: { _ in NativeMetalWorldRunner(executor: nil) })
        let sample = NativeMetalQualitySample(report: try XCTUnwrap(matrix.runs.first))
        XCTAssertNil(sample.maximumRestDisplacementRadiusFraction)
        XCTAssertNil(sample.releasedContourMeanRadiusErrorFraction)
        XCTAssertNil(sample.publishedStateHash)
        let text = matrix.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("native_quality_envelope=fail"))
        XCTAssertTrue(text.contains("native_quality_violation limit=4 reason=missingEvidence"))
        XCTAssertTrue(text.contains("rest_displacement_radius_fraction=unavailable"))
    }

    func testZeroMeasuredFramesCannotFabricateQualityAcceptance() async throws {
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: .init(scene: .interactive24,
            warmupSteps: 0, measuredSteps: 0, iterationLimits: [4], backend: .nativeMetal))
        let text = matrix.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("native_quality_envelope=fail"))
        XCTAssertTrue(text.contains("native_quality_violation limit=4 reason=missingEvidence"))
    }

    // A fallback in an auxiliary batch must reject quality even when all timed
    // GPU frames and the repeated convergence sequence completed successfully.
    func testControlBatchFallbackCannotBeHiddenByEligibleTimedGPUFrames() async throws {
        let factory = ControlBatchFallbackFactory()
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: configuration(),
            makeRunner: { limit in try factory.make(limit: limit) })
        let run = try XCTUnwrap(matrix.runs.first)
        XCTAssertTrue(run.isGPUAcceptanceMeasurementEligible)
        XCTAssertEqual(run.completedMetalSampleCount, 2)
        XCTAssertNil(run.nativeQuality?.maximumRestDisplacementRadiusFraction)
        XCTAssertNotNil(run.nativeQuality?.releasedContourMeanRadiusErrorFraction)
        XCTAssertNotNil(run.nativeQuality?.repeatedPublishedStateHash)
        XCTAssertEqual(run.nativeQuality?.violations, ["missingEvidence"])
        let text = matrix.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("native_quality_envelope=fail"))
        XCTAssertTrue(text.contains("rest_displacement_radius_fraction=unavailable"))
    }

    // Catches treating native publication as CPU or omitting the actual CB profile.
    func testNativeBenchmarkReportsOneCommandBufferAndNoFallback() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device") }
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: configuration())
        let run = try XCTUnwrap(matrix.runs.first)
        XCTAssertEqual(run.backend, .nativeMetal)
        XCTAssertEqual(run.metalFrameCount, 3)
        XCTAssertEqual(run.cpuFrameCount, 0)
        XCTAssertEqual(run.fallbackCount, 0)
        XCTAssertEqual(run.completedMetalSampleCount, 2)
        XCTAssertEqual(run.gpuProfileSampleCount, 2)
        XCTAssertEqual(run.gpuProfileCommandBuffers.maximumMilliseconds, 1)
        XCTAssertEqual(run.maximumNativeSolverIterations, 4)
        XCTAssertGreaterThan(run.solver.p95Milliseconds, 0)
        XCTAssertEqual(run.solver.p95Milliseconds, run.completedMetalTiming.p95Milliseconds)
        XCTAssertTrue(run.isGPUAcceptanceMeasurementEligible)
        let text = matrix.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("native_solver_iterations=4"))
        XCTAssertTrue(text.contains("native_cache_hits="))
        XCTAssertTrue(text.contains("native_cache_resets="))
        XCTAssertTrue(text.contains("native_ccd_candidates="))
        XCTAssertTrue(text.contains("command_buffers_max=1.0000"))
        XCTAssertTrue(text.contains("host_readback_p50_ms=unavailable"))
    }

    // An unavailable executor must not contribute GPU times or native cache data.
    func testCPUFallbackIsExcludedFromNativeCompletedSamples() async throws {
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: configuration(),
            makeRunner: { _ in NativeMetalWorldRunner(executor: nil) })
        let run = try XCTUnwrap(matrix.runs.first)
        XCTAssertEqual(run.cpuFrameCount, 3)
        XCTAssertEqual(run.metalFrameCount, 0)
        XCTAssertEqual(run.fallbackCount, 3)
        XCTAssertEqual(run.warmupFallbackCount, 1)
        XCTAssertEqual(run.completedMetalSampleCount, 0)
        XCTAssertEqual(run.gpuProfileSampleCount, 0)
        XCTAssertEqual(run.cpuFallbackSampleCount, 2)
        XCTAssertNil(run.maximumNativeSolverIterations)
        XCTAssertFalse(run.isGPUAcceptanceMeasurementEligible)
        let text = matrix.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("gpu_completed limit=4 measured_frames=0 command_buffers_p50_ms=unavailable"))
        XCTAssertTrue(text.contains("native_solver_iterations=unavailable"))
    }

    private func configuration() -> ReferenceBenchmarkMatrixConfiguration {
        .init(scene: .interactive24, warmupSteps: 1, measuredSteps: 2,
              iterationLimits: [4], backend: .nativeMetal)
    }

    func testMixedRunKeepsOnlyPublishedNativeFramesInGPUProfile() async throws {
        let executor = FailSecondNativeBenchmarkFrame(solver: try NativeMetalSolver(
            device: XCTUnwrap(MTLCreateSystemDefaultDevice()), configuration: .init(solverIterationCount: 4)))
        let config = ReferenceBenchmarkMatrixConfiguration(scene: .interactive24,
            warmupSteps: 0, measuredSteps: 2, iterationLimits: [4], backend: .nativeMetal)
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: config,
            makeRunner: { _ in NativeMetalWorldRunner(executor: executor) })
        let run = try XCTUnwrap(matrix.runs.first)
        XCTAssertEqual(run.cpuFrameCount, 1)
        XCTAssertEqual(run.metalFrameCount, 1)
        XCTAssertEqual(run.completedMetalSampleCount, 1)
        XCTAssertEqual(run.gpuProfileSampleCount, 1)
        XCTAssertEqual(run.nativeTelemetrySampleCount, 1)
        XCTAssertEqual(run.cpuFallbackSampleCount, 1)
        XCTAssertEqual(run.gpuProfileCommandBuffers.maximumMilliseconds, 1)
        XCTAssertEqual(run.fallbackCount, 1)
        XCTAssertFalse(run.isGPUAcceptanceMeasurementEligible)
    }

    func testRejectedNonFiniteGPUAttemptRemainsVisibleAfterFiniteCPUFallback() async throws {
        let matrix = try await NativeMetalBenchmarkRunner.measure(configuration: configuration(),
            makeRunner: { _ in NativeMetalWorldRunner(executor: NonFiniteNativeBenchmarkFrame()) })
        let run = try XCTUnwrap(matrix.runs.first)
        XCTAssertEqual(run.cpuFrameCount, 3)
        XCTAssertEqual(run.completedMetalSampleCount, 0)
        XCTAssertTrue(run.hasNonFiniteState)
        XCTAssertEqual(run.fallbackReasons["nonFinite"], 3)
    }
}

@MainActor
private final class ControlBatchFallbackFactory {
    var count = 0
    func make(limit: Int) throws -> NativeMetalWorldRunner {
        count += 1
        if count == 3 { return NativeMetalWorldRunner(executor: nil) }
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(solverIterationCount: limit))
        return NativeMetalWorldRunner(executor: solver)
    }
}

@MainActor
private final class NonFiniteNativeBenchmarkFrame: NativeMetalFrameExecuting {
    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        throw NativeMetalSafetyFailure(reason: .nonFinite,
            telemetry: .init(backend: .nativeMetal, didEncounterNonFinite: true), profile: .init())
    }
}

@MainActor
private final class FailSecondNativeBenchmarkFrame: NativeMetalFrameExecuting {
    let solver: NativeMetalSolver
    init(solver: NativeMetalSolver) { self.solver = solver }
    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        if scenarioStep == 1 { throw NativeMetalWorldError.unavailable }
        return try await solver.executeFrame(world: world, scenarioStep: scenarioStep)
    }
}
