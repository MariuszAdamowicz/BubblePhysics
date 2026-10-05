import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

@MainActor
final class ReferenceMetalStagedWorldTests: XCTestCase {
    func testEmptyFrameHasConvergedReportAndNoLineSearchFailure() async throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        var cpu = world
        let expected = cpu.step()
        let runner = ReferenceMetalWorldRunner(executor: try makeSolver { command, _, _ in try await Self.complete(command) })
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertEqual(actual.solver, expected.solver)
        XCTAssertEqual(runner.telemetry.solveCallCount, 1)
        XCTAssertEqual(runner.telemetry.tentativeSolveCallCount, 1)
        XCTAssertEqual(runner.telemetry.contactCount, 0)
        XCTAssertEqual(runner.telemetry.ccdGroupCount, 0)
    }

    func testFailureAfterPCGDiscardsSolvedScratchAndLaterFrameStartsFromFreshInput() async throws {
        var failed = false
        let runner = ReferenceMetalWorldRunner(executor: try makeSolver { command, stage, step in
            try await Self.complete(command)
            if !failed && stage == "referenceWorld.pcg.0.0" {
                failed = true
                throw ReferenceMetalGPUFailure(stage: stage, scenarioStep: step,
                    error: NSError(domain: MTLCommandBufferErrorDomain, code: 9), commandBufferStatus: 5)
            }
        })
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()
        var cpu = try scenario.makeWorld()
        for step in 1...2 {
            scenario.updatePolygon(in: &world, fromStep: step - 1, toStep: step)
            scenario.updatePolygon(in: &cpu, fromStep: step - 1, toStep: step)
            let expected = cpu.step()
            let actual = await runner.step(world: &world, scenarioStep: step)
            if step == 1 {
                XCTAssertEqual(world.bubbles, cpu.bubbles)
                XCTAssertEqual(world.contacts.contacts, cpu.contacts.contacts)
                XCTAssertEqual(actual.solver, expected.solver)
                XCTAssertEqual(runner.telemetry.backend, .cpu)
                XCTAssertEqual(runner.telemetry.gpuFailure?.stage, "referenceWorld.pcg.0.0")
                XCTAssertTrue(runner.contours.isEmpty)
                XCTAssertTrue(runner.renderData.isEmpty)
            } else {
                XCTAssertEqual(runner.telemetry.backend, .metal)
                XCTAssertNil(runner.telemetry.gpuFailure)
                for (bubble, oracle) in zip(world.bubbles, cpu.bubbles) {
                    XCTAssertEqual(bubble.center.x, oracle.center.x, accuracy: 0.05)
                    XCTAssertEqual(bubble.center.y, oracle.center.y, accuracy: 0.05)
                }
            }
        }
    }

    // A geometry-stage failure must discard real GPU scratch and replay the
    // entire frame from its original input, including contacts and rotation.
    func testFailureAfterGeometryPublishesOnlyWholeCPUFrame() async throws {
        var stages: [String] = []
        let solver = try makeSolver { command, stage, step in
            try await Self.complete(command)
            stages.append(stage)
            if stage == "referenceWorld.geometry" {
                throw ReferenceMetalGPUFailure(stage: stage, scenarioStep: step,
                    error: NSError(domain: MTLCommandBufferErrorDomain, code: 9), commandBufferStatus: 5)
            }
        }
        let runner = ReferenceMetalWorldRunner(executor: solver)
        // This frame fits the initial capacity, so geometry creates prediction
        // scratch before the failure (rather than merely reporting overflow).
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 91), center: .init(x: 2, y: -3),
            velocity: .init(x: 7, y: 5), mass: 2, targetRadius: 1,
            rotation: 0.2, angularVelocity: 3))
        var cpu = world
        let expected = cpu.step()
        let result = await runner.step(world: &world, scenarioStep: 1)
        XCTAssertEqual(world.bubbles, cpu.bubbles)
        XCTAssertEqual(world.contacts.contacts, cpu.contacts.contacts)
        XCTAssertEqual(result.solver, expected.solver)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertEqual(runner.telemetry.gpuFailure?.stage, "referenceWorld.geometry")
        XCTAssertEqual(stages, ["referenceWorld.geometry"])
        XCTAssertTrue(runner.contours.isEmpty)
        XCTAssertTrue(runner.renderData.isEmpty)
        XCTAssertNil(runner.telemetry.solveCallCount)
        XCTAssertNil(runner.telemetry.tentativeSolveCallCount)
        XCTAssertNil(runner.telemetry.contactCount)
        XCTAssertNil(runner.telemetry.ccdGroupCount)
    }

    // Removing parallel operator/PCG stages, or mixing partial frame outputs,
    // breaks the stage evidence or the independently computed CPU quality.
    func testShortInteractive24UsesStagedPCGAndMatchesCPUQuality() async throws {
        var stages: [String] = []
        let runner = ReferenceMetalWorldRunner(executor: try makeSolver { command, stage, _ in
            try await Self.complete(command)
            stages.append(stage)
        })
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()
        var cpu = try scenario.makeWorld()
        var iterations = 0
        for step in 1...4 {
            scenario.updatePolygon(in: &world, fromStep: step - 1, toStep: step)
            scenario.updatePolygon(in: &cpu, fromStep: step - 1, toStep: step)
            let expected = cpu.step()
            let actual = await runner.step(world: &world, scenarioStep: step)
            XCTAssertEqual(runner.telemetry.backend, .metal, runner.telemetry.fallbackReason ?? "")
            XCTAssertGreaterThan(try XCTUnwrap(runner.telemetry.solveCallCount), actual.solverSubstepCount,
                "Discarded tentative solves must remain visible in GPU work telemetry")
            XCTAssertGreaterThan(try XCTUnwrap(runner.telemetry.tentativeSolveCallCount), 0)
            XCTAssertEqual(runner.telemetry.contactCount, world.contacts.contacts.count)
            XCTAssertEqual(runner.telemetry.ccdGroupCount, actual.eventGroupCount)
            XCTAssertEqual(actual.solver.finalResidualNorm, expected.solver.finalResidualNorm,
                accuracy: max(0.01, expected.solver.finalResidualNorm * 0.02))
            XCTAssertEqual(actual.solver.maximumPenetration, expected.solver.maximumPenetration, accuracy: 0.05)
            XCTAssertEqual(actual.solver.unconvergedContactComponentCount, expected.solver.unconvergedContactComponentCount)
            iterations += actual.solver.pcgIterationCount
            for (bubble, oracle) in zip(world.bubbles, cpu.bubbles) {
                XCTAssertEqual(bubble.center.x, oracle.center.x, accuracy: 0.05)
                XCTAssertEqual(bubble.center.y, oracle.center.y, accuracy: 0.05)
                XCTAssertTrue(try XCTUnwrap(runner.contours[bubble.id]).allSatisfy(\.isFinite))
            }
        }
        XCTAssertGreaterThan(iterations, 0)
        XCTAssertTrue(stages.contains { $0.hasPrefix("referenceWorld.newton") })
        XCTAssertTrue(stages.contains { $0.hasPrefix("referenceWorld.pcg") })
        XCTAssertEqual(stages.filter { $0 == "referenceWorld.render" }.count, 4)
    }

    // A candidate outside the activated group prefix still replaces an earlier
    // event with the same historical 32-bit stable key.
    func testStableKeyLastWriterOutsideEventPrefixMatchesCPU() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0, maximumEventGroups: 1),
            broadPhase: BruteForceBroadPhase())
        let ids = [1, 2, 4_294_967_297, 4_294_967_298]
        let x: [Float] = [0, 1.5, 100, 103]
        let velocity: [Float] = [0, 0, 0.75, -0.75]
        for i in ids.indices {
            world.addBubble(try .init(id: .init(rawValue: ids[i]), center: .init(x: x[i], y: 0),
                velocity: .init(x: velocity[i], y: 0), mass: 1, targetRadius: 1))
        }
        var cpu = world
        let expected = cpu.step()
        XCTAssertEqual(cpu.contacts.contacts.map { $0.bubbleA.rawValue }, [4_294_967_297])
        let runner = ReferenceMetalWorldRunner(executor: try makeSolver { command, _, _ in try await Self.complete(command) })
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertEqual(world.contacts.contacts.map(\.bubbleA), cpu.contacts.contacts.map(\.bubbleA))
        XCTAssertEqual(world.contacts.contacts.map(\.bubbleB), cpu.contacts.contacts.map(\.bubbleB))
        XCTAssertEqual(actual.generatedContactCount, expected.generatedContactCount)
        XCTAssertEqual(actual.didReachEventGroupLimit, expected.didReachEventGroupLimit)
        for (bubble, oracle) in zip(world.bubbles, cpu.bubbles) {
            XCTAssertEqual(bubble.center.x, oracle.center.x, accuracy: 0.001)
        }
    }

    private func makeSolver(completion: @escaping @MainActor (MTLCommandBuffer, String, Int) async throws -> Void) throws -> ReferenceMetalSolver {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return try XCTUnwrap(ReferenceMetalSolver(device: device, completeFrameCommand: completion))
    }

    private static func complete(_ command: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            command.addCompletedHandler { result in
                if result.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: result.error ?? ReferenceMetalOperatorError.commandSetupFailed) }
            }
            command.commit()
        }
    }
}
