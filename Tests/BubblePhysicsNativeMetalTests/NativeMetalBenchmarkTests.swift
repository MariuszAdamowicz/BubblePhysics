import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalBenchmarkTests: XCTestCase {
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
