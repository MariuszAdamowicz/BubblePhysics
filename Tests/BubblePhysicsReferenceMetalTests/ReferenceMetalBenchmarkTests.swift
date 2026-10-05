import XCTest
import Metal
@testable import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

@MainActor
final class ReferenceMetalBenchmarkTests: XCTestCase {
    func testGPUReportPreservesQualityColumnsAndRecordsActualFrames() async throws {
        let report = try await measure(warmup: 1, measured: 2)
        let run = try XCTUnwrap(report.runs.first)
        XCTAssertEqual(run.backend, .metal)
        XCTAssertEqual(run.metalFrameCount, 3)
        XCTAssertEqual(run.cpuFrameCount, 0)
        XCTAssertEqual(run.fallbackCount, 0)
        XCTAssertTrue(run.isGPUAcceptanceMeasurementEligible)
        let text = report.plainText(deviceName: "test host", systemVersion: "test")
        let header = "limit full_p50_ms full_p95_ms full_max_ms solver_p95_ms contour_p95_ms render_p95_ms penetration_p95 penetration_max residual_p95 residual_max unconverged_components containment non_finite"
        XCTAssertTrue(text.contains(header + " backend cpu_frames metal_frames fallbacks warmup_fallbacks gpu_measurement"))
        let row = try XCTUnwrap(text.split(separator: "\n").first { $0.hasPrefix("4 ") }).split(separator: " ")
        XCTAssertEqual(row[0], "4")
        XCTAssertEqual(row[11], Substring(String(run.maximumUnconvergedContactComponents)))
        XCTAssertEqual(Array(row.suffix(6)), ["metal", "0", "3", "0", "0", "eligible"])
        XCTAssertFalse(run.hasNonFiniteState)
    }

    func testWarmupFallbackDisqualifiesOtherwisePureMeasuredGPUFrames() async throws {
        let report = try await measure(warmup: 1, measured: 2, failingStep: 0)
        let run = try XCTUnwrap(report.runs.first)
        XCTAssertEqual(run.cpuFrameCount, 1)
        XCTAssertEqual(run.metalFrameCount, 2)
        XCTAssertEqual(run.fallbackCount, 1)
        XCTAssertEqual(run.warmupFallbackCount, 1)
        XCTAssertEqual(run.fallbackReasons["injectedFailure"], 1)
        XCTAssertFalse(run.isGPUAcceptanceMeasurementEligible)
        XCTAssertTrue(report.plainText(deviceName: "test", systemVersion: "test").contains("metal 1 2 1 1 ineligible"))
    }

    func testCopiedGPUReportExplainsCompleteCommandBufferAndHostContourTiming() async throws {
        let report = try await measure(warmup: 0, measured: 1)
        let text = report.plainText(deviceName: "test host", systemVersion: "test")
        XCTAssertTrue(text.contains("solver_p95_ms obejmuje cały command buffer GPU"))
        XCTAssertTrue(text.contains("contour_p95_ms mierzy pobranie/pakowanie konturów na hoście"))
    }

    func testCPUReportKeepsExistingFormatWithoutGPUExplanation() async throws {
        let report = try await ReferenceBenchmarkMatrixRunner.measure(configuration: .init(
            scene: .interactive24, warmupSteps: 0, measuredSteps: 0, iterationLimits: [4]))
        XCTAssertEqual(report.plainText(deviceName: "test host", systemVersion: "test"), """
        BubblePhysics reference convergence benchmark
        device: test host
        system: test
        scene: interactive-24
        seed: 2842869
        warmup: 0 measured: 0
        limit full_p50_ms full_p95_ms full_max_ms solver_p95_ms contour_p95_ms render_p95_ms penetration_p95 penetration_max residual_p95 residual_max unconverged_components containment non_finite backend cpu_frames metal_frames fallbacks warmup_fallbacks gpu_measurement
        4 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0.0000 0 0 no cpu 0 0 0 0 not_applicable
        """)
    }

    func testMeasuredFallbackDisqualifiesRunAndKeepsCPUQuality() async throws {
        let report = try await measure(warmup: 0, measured: 1, failingStep: 0)
        let gpu = try XCTUnwrap(report.runs.first)
        let cpu = try ReferenceBenchmarkRunner.measure(
            scenario: .init(scene: .interactive24, newtonIterationLimit: 4), warmupSteps: 0, measuredSteps: 1)
        XCTAssertEqual(gpu.penetration, cpu.penetration)
        XCTAssertEqual(gpu.finalResidual, cpu.finalResidual)
        XCTAssertEqual(gpu.maximumUnconvergedContactComponents, cpu.maximumUnconvergedContactComponents)
        XCTAssertEqual(gpu.fallbackCount, 1)
        XCTAssertEqual(gpu.warmupFallbackCount, 0)
        XCTAssertFalse(gpu.isGPUAcceptanceMeasurementEligible)
    }

    func testCPUAndGPUUseIdenticalSeedStepsAndIterationLimits() async throws {
        let configuration = ReferenceBenchmarkMatrixConfiguration(
            scene: .interactive24, seed: 17, warmupSteps: 1, measuredSteps: 1,
            iterationLimits: [4, 8, 12, 16], backend: .metal)
        var executors: [RecordingBenchmarkExecutor] = []
        let gpu = try await ReferenceMetalBenchmarkRunner.measure(configuration: configuration, makeRunner: {
            let executor = RecordingBenchmarkExecutor(solver: try self.solver())
            executors.append(executor)
            return ReferenceMetalWorldRunner(executor: executor)
        })
        var cpuConfiguration = configuration
        cpuConfiguration.backend = .cpu
        let cpu = try await ReferenceBenchmarkMatrixRunner.measure(configuration: cpuConfiguration)
        XCTAssertEqual(gpu.runs.map(\.seed), [17, 17, 17, 17])
        XCTAssertEqual(gpu.runs.map(\.newtonIterationLimit), [4, 8, 12, 16])
        XCTAssertEqual(gpu.runs.map(\.pcgIterationLimit), cpu.runs.map(\.pcgIterationLimit))
        XCTAssertEqual(gpu.runs.map(\.timeStep), cpu.runs.map(\.timeStep))
        XCTAssertEqual(gpu.runs.map(\.stressTolerance), cpu.runs.map(\.stressTolerance))
        XCTAssertEqual(gpu.runs.map(\.warmupSteps), [1, 1, 1, 1])
        XCTAssertEqual(gpu.runs.map(\.measuredSteps), [1, 1, 1, 1])
        for (executor, limit) in zip(executors, [4, 8, 12, 16]) {
            XCTAssertEqual(executor.steps, [0, 1])
            XCTAssertEqual(executor.limits, [limit, limit])
            var world = try ReferenceConvergenceScenario(scene: .interactive24, seed: 17, newtonIterationLimit: limit).makeWorld()
            ReferenceConvergenceScenario(scene: .interactive24, seed: 17, newtonIterationLimit: limit)
                .updatePolygon(in: &world, fromStep: 0, toStep: 1)
            XCTAssertEqual(executor.firstCenters, ReferenceMetalSnapshot(world: world).centers)
        }
    }

    func testPublicGPUSelectionOnHostReportsUnsupportedFallback() async throws {
        #if !os(iOS)
        let report = try await ReferenceMetalBenchmarkRunner.measure(configuration: .init(
            scene: .interactive24, warmupSteps: 1, measuredSteps: 1, iterationLimits: [4], backend: .metal))
        let run = try XCTUnwrap(report.runs.first)
        XCTAssertEqual(run.cpuFrameCount, 2)
        XCTAssertEqual(run.metalFrameCount, 0)
        XCTAssertEqual(run.fallbackReasons["unsupportedRuntime"], 2)
        XCTAssertFalse(run.isGPUAcceptanceMeasurementEligible)
        #endif
    }

    func testEmptyGPURunCannotBecomeAcceptanceMeasurement() async throws {
        let report = try await measure(warmup: 0, measured: 0)
        XCTAssertFalse(try XCTUnwrap(report.runs.first).isGPUAcceptanceMeasurementEligible)
    }

    // Catches a report that silently merges completed GPU time and fallback CPU
    // time, or loses the original failure after the session latch takes over.
    func testFatalLatchCountsEveryCPUFrameAndReportsOnlyCompletedMetalTiming() async throws {
        let failure = ReferenceMetalGPUFailure(stage: "pcg.direction\nforged_row", scenarioStep: 1,
            error: NSError(domain: MTLCommandBufferErrorDomain, code: 2,
                userInfo: [NSLocalizedDescriptionKey: "watchdog\nreason=forged"]), commandBufferStatus: 5)
        let report = try await ReferenceMetalBenchmarkRunner.measure(configuration: .init(
            scene: .interactive24, warmupSteps: 0, measuredSteps: 3, iterationLimits: [4], backend: .metal),
            makeRunner: {
                ReferenceMetalWorldRunner(executor: RecordingBenchmarkExecutor(
                    solver: try self.solver(), failingStep: 1, gpuFailure: failure, fixedTelemetry: true))
            })
        let run = try XCTUnwrap(report.runs.first)
        XCTAssertEqual(run.metalFrameCount, 1)
        XCTAssertEqual(run.cpuFrameCount, 2)
        XCTAssertEqual(run.fallbackCount, 2)
        XCTAssertFalse(run.isGPUAcceptanceMeasurementEligible)
        let text = report.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("gpu_completed limit=4 measured_frames=1 command_buffers_p50_ms=2.0000 command_buffers_p95_ms=2.0000 command_buffers_max_ms=2.0000"))
        XCTAssertTrue(text.contains("cpu_fallback limit=4 measured_frames=2"))
        XCTAssertTrue(text.contains("gpu_work limit=4 scope=completed_measured_frames solve_calls_max=7 tentative_solve_calls_max=3 contacts_max=11 ccd_groups_max=2"))
        XCTAssertTrue(text.contains("gpu_fatal_failure limit=4 stage=pcg.direction forged_row step=1 classification=timeout reason=watchdog reason=forged"))
        XCTAssertFalse(text.contains("\nforged_row"))
        XCTAssertFalse(text.contains("\nreason=forged"))
    }

    // A warmup success must not become a measured GPU sample after fatal failure.
    func testFatalFailureAfterWarmupLeavesNoMeasuredGPUTime() async throws {
        let failure = ReferenceMetalGPUFailure(stage: "geometry", scenarioStep: 1,
            error: NSError(domain: MTLCommandBufferErrorDomain, code: 2))
        let report = try await ReferenceMetalBenchmarkRunner.measure(configuration: .init(
            scene: .interactive24, warmupSteps: 1, measuredSteps: 2, iterationLimits: [4], backend: .metal),
            makeRunner: {
                ReferenceMetalWorldRunner(executor: RecordingBenchmarkExecutor(
                    solver: try self.solver(), failingStep: 1, gpuFailure: failure, fixedTelemetry: true))
            })
        let run = try XCTUnwrap(report.runs.first)
        XCTAssertEqual(run.warmupFallbackCount, 0)
        XCTAssertEqual(run.fallbackCount, 2)
        XCTAssertFalse(run.isGPUAcceptanceMeasurementEligible)
        let text = report.plainText(deviceName: "test", systemVersion: "test")
        XCTAssertTrue(text.contains("gpu_completed limit=4 measured_frames=0 command_buffers_p50_ms=unavailable command_buffers_p95_ms=unavailable command_buffers_max_ms=unavailable"))
        XCTAssertTrue(text.contains("gpu_work limit=4 scope=completed_measured_frames solve_calls_max=unavailable"))
    }

    func testCPUOnlyMatrixCannotSilentlyLabelMetalConfigurationAsGPU() async throws {
        do {
            _ = try await ReferenceBenchmarkMatrixRunner.measure(configuration: .init(
                scene: .interactive24, warmupSteps: 0, measuredSteps: 1, iterationLimits: [4], backend: .metal))
            XCTFail("CPU-only entry point must reject Metal selection")
        } catch ReferenceBenchmarkError.backendRequiresFrameExecutor { }
    }

    private func measure(warmup: Int, measured: Int, failingStep: Int? = nil) async throws -> ReferenceBenchmarkMatrixReport {
        try await ReferenceMetalBenchmarkRunner.measure(configuration: .init(
            scene: .interactive24, warmupSteps: warmup, measuredSteps: measured, iterationLimits: [4], backend: .metal),
            makeRunner: {
                ReferenceMetalWorldRunner(executor: RecordingBenchmarkExecutor(solver: try self.solver(), failingStep: failingStep))
            })
    }

    private func solver() throws -> ReferenceMetalSolver {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device on test host") }
        return try XCTUnwrap(ReferenceMetalSolver(device: device))
    }
}

@MainActor
private final class RecordingBenchmarkExecutor: ReferenceMetalFrameExecuting {
    enum Failure: Error { case injectedFailure }
    let solver: ReferenceMetalSolver
    let failingStep: Int?
    let gpuFailure: ReferenceMetalGPUFailure?
    let fixedTelemetry: Bool
    var steps: [Int] = []
    var limits: [Int] = []
    var firstCenters: [SIMD2<Float>]?
    init(solver: ReferenceMetalSolver, failingStep: Int? = nil,
         gpuFailure: ReferenceMetalGPUFailure? = nil, fixedTelemetry: Bool = false) {
        self.solver = solver
        self.failingStep = failingStep
        self.gpuFailure = gpuFailure
        self.fixedTelemetry = fixedTelemetry
    }
    func executeFrame(snapshot: ReferenceMetalSnapshot, scenarioStep: Int) async throws -> ReferenceMetalWorldFrame {
        steps.append(scenarioStep)
        limits.append(snapshot.configuration.solverIterations)
        if firstCenters == nil { firstCenters = snapshot.centers }
        if scenarioStep == failingStep {
            if let gpuFailure { throw gpuFailure }
            throw Failure.injectedFailure
        }
        var frame = try await solver.executeFrame(snapshot: snapshot, scenarioStep: scenarioStep)
        if fixedTelemetry {
            frame.telemetry = .init(backend: .metal, frameMilliseconds: 900, gpuMilliseconds: 2,
                finalResidual: frame.report.solver.finalResidualNorm,
                solveCallCount: 7, tentativeSolveCallCount: 3, contactCount: 11, ccdGroupCount: 2)
            frame.report.solverMilliseconds = 999
        }
        return frame
    }
}
