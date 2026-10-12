import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

@MainActor
final class ReferenceMetalWorldRunnerTests: XCTestCase {
    func testInteractive24PreservesReactivatedBubbleContactAtStep15() async throws {
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()
        for step in 1...15 {
            scenario.updatePolygon(in: &world, fromStep: step - 1, toStep: step)
            _ = await runner.step(world: &world, scenarioStep: step)
            XCTAssertEqual(runner.telemetry.backend, .metal)
            XCTAssertNil(runner.telemetry.fallbackReason)
        }
        // Task 5 baseline: the renewed bubble–bubble contact survives the
        // solve.2 refresh alongside two segment contacts.
        XCTAssertEqual(world.contacts.contacts.map { $0.id.rawValue },
            [60_129_542_159, 9_223_372_066_919_546_886, 9_223_372_066_919_546_887])
    }

    func testWorldRefreshUsesParallelContactStageWithoutChangingContactIDs() async throws {
        let solver = try XCTUnwrap(ReferenceMetalSolver(device: MTLCreateSystemDefaultDevice()))
        XCTAssertTrue(solver.loadedFunctionNames.contains("referenceWorldRefreshFlags"))
        let runner = ReferenceMetalWorldRunner(executor: solver)
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4)
        var cpu = try scenario.makeWorld()
        var gpu = cpu
        scenario.updatePolygon(in: &cpu, fromStep: 0, toStep: 1)
        scenario.updatePolygon(in: &gpu, fromStep: 0, toStep: 1)
        _ = cpu.step()
        _ = await runner.step(world: &gpu, scenarioStep: 1)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertEqual(gpu.contacts.contacts.map(\.id), cpu.contacts.contacts.map(\.id))
    }
    func testInteractive24PublishesFiniteGPUFramesWithinCPUQualityTolerance() async throws {
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4)
        var cpu = try scenario.makeWorld()
        var gpu = try scenario.makeWorld()
        var pcgIterations = 0
        var eventGroups = 0
        for step in 1...4 {
            scenario.updatePolygon(in: &cpu, fromStep: step - 1, toStep: step)
            scenario.updatePolygon(in: &gpu, fromStep: step - 1, toStep: step)
            let oracle = cpu.step()
            let actual = await runner.step(world: &gpu, scenarioStep: step)
            pcgIterations += actual.solver.pcgIterationCount
            eventGroups += actual.eventGroupCount
            XCTAssertEqual(runner.telemetry.backend, .metal)
            XCTAssertNil(runner.telemetry.fallbackReason)
            XCTAssertFalse(actual.hasNonFiniteState)
            XCTAssertEqual(actual.solver.finalResidualNorm, oracle.solver.finalResidualNorm,
                           accuracy: max(0.01, oracle.solver.finalResidualNorm * 0.02))
            XCTAssertEqual(actual.solver.maximumPenetration, oracle.solver.maximumPenetration, accuracy: 0.05)
            XCTAssertEqual(actual.solver.unconvergedContactComponentCount, oracle.solver.unconvergedContactComponentCount)
            for (a, b) in zip(gpu.bubbles, cpu.bubbles) {
                XCTAssertEqual(a.center.x, b.center.x, accuracy: 0.05)
                XCTAssertEqual(a.center.y, b.center.y, accuracy: 0.05)
                let contour = try XCTUnwrap(runner.contours[a.id])
                XCTAssertEqual(contour.count, cpu.contour(for: b.id).count)
                XCTAssertTrue(contour.allSatisfy(\.isFinite))
                for (point, expected) in zip(contour, cpu.contour(for: b.id)) {
                    XCTAssertEqual(point.x, expected.x, accuracy: 0.05)
                    XCTAssertEqual(point.y, expected.y, accuracy: 0.05)
                }
            }
        }
        XCTAssertGreaterThan(pcgIterations, 0)
        XCTAssertGreaterThan(eventGroups, 0)
    }

    func testCompletedGPUThenInjectedFailureFallsBackEntireFrameFromOriginalState() async throws {
        let runner = ReferenceMetalWorldRunner(executor: FailureAfterGPU(executor: try executor()))
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()
        scenario.updatePolygon(in: &world, fromStep: 0, toStep: 1)
        var oracle = world
        let expected = oracle.step()
        let actual = await runner.step(world: &world, scenarioStep: 1)
        XCTAssertEqual(world.bubbles, oracle.bubbles)
        XCTAssertEqual(world.contacts.contacts, oracle.contacts.contacts)
        XCTAssertEqual(actual.solver, expected.solver)
        XCTAssertEqual(actual.eventGroupCount, expected.eventGroupCount)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertNotNil(runner.telemetry.fallbackReason)
        XCTAssertEqual(runner.telemetry.finalResidual, expected.solver.finalResidualNorm)
        XCTAssertTrue(runner.contours.isEmpty)
    }

    func testClosedPolygonPostSolveExpelsCenterAndRemovesOwnerContacts() async throws {
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 3))
        let vertices: [ReferenceVector2] = [.init(x: -2, y: -2), .init(x: 2, y: -2), .init(x: 2, y: 2), .init(x: -2, y: 2)]
        for i in vertices.indices {
            world.addSegment(.staticSegment(id: .init(rawValue: i), a: vertices[i], b: vertices[(i + 1) % 4], ownerID: 9))
        }
        var cpu = world
        let expected = cpu.step()
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertGreaterThanOrEqual(max(abs(world.bubbles[0].center.x), abs(world.bubbles[0].center.y)), 2)
        XCTAssertEqual(actual.centerGuardCount, expected.centerGuardCount)
        XCTAssertEqual(world.bubbles[0].center.x, cpu.bubbles[0].center.x, accuracy: 0.001)
        XCTAssertEqual(world.bubbles[0].center.y, cpu.bubbles[0].center.y, accuracy: 0.001)
        XCTAssertTrue(world.contacts.contacts.isEmpty)
    }

    func testPublicRuntimeSelectionUsesMetalWhenDeviceIsAvailable() async throws {
        guard MTLCreateSystemDefaultDevice() != nil else { throw XCTSkip("No Metal device on test host") }
        let runner = ReferenceMetalWorldRunner(backend: .metal)
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()
        scenario.updatePolygon(in: &world, fromStep: 0, toStep: 1)
        _ = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertNil(runner.telemetry.fallbackReason)
    }

    func testMissingExecutorFallsBackToWholeCPUFrame() async throws {
        let runner = ReferenceMetalWorldRunner(backend: .metal, makeExecutor: { nil })
        var world = try ReferenceConvergenceScenario(scene: .interactive24, newtonIterationLimit: 4).makeWorld()
        var oracle = world
        _ = oracle.step()
        _ = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertEqual(runner.telemetry.fallbackReason, "unavailable")
        XCTAssertEqual(world.bubbles, oracle.bubbles)
        XCTAssertEqual(world.contacts.contacts, oracle.contacts.contacts)
    }

    func testFiniteButContainedGPUCandidateTriggersAtomicCPUFallback() async throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: 3, y: 0), mass: 1, targetRadius: 0.2))
        let vertices: [ReferenceVector2] = [.init(x: -2, y: -2), .init(x: 2, y: -2), .init(x: 2, y: 2), .init(x: -2, y: 2)]
        for i in vertices.indices {
            world.addSegment(.staticSegment(id: .init(rawValue: i), a: vertices[i], b: vertices[(i + 1) % 4], ownerID: 9))
        }
        var oracle = world
        let expected = oracle.step()
        let runner = ReferenceMetalWorldRunner(executor: CorruptGPU(executor: try executor(), corruption: .contained))
        let result = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertEqual(runner.telemetry.fallbackReason, "guardFailed")
        XCTAssertEqual(world.bubbles, oracle.bubbles)
        XCTAssertEqual(result.solver, expected.solver)
    }

    func testIncompleteRenderCandidateTriggersAtomicCPUFallback() async throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 1))
        var oracle = world
        _ = oracle.step()
        let runner = ReferenceMetalWorldRunner(executor: CorruptGPU(executor: try executor(), corruption: .render))
        _ = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertEqual(world.bubbles, oracle.bubbles)
        XCTAssertNotNil(runner.telemetry.fallbackReason)
    }

    func testNonFiniteRefreshCannotDisappearAsContactFreeSuccess() async throws {
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 1.5, y: 0), mass: 1, targetRadius: 1))
        _ = world.step()
        XCTAssertFalse(world.contacts.contacts.isEmpty)
        for i in world.bubbles.indices {
            var bubble = world.bubbles[i]
            bubble.center = .init(x: i == 0 ? -1e20 : 1e20, y: 0)
            bubble.velocity = .zero
            world.updateBubble(bubble)
        }
        var oracle = world
        _ = oracle.step()
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        _ = await runner.step(world: &world, scenarioStep: 1)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertEqual(runner.telemetry.fallbackReason, "nonFiniteState")
        XCTAssertEqual(world.bubbles, oracle.bubbles)
        XCTAssertEqual(world.contacts.contacts, oracle.contacts.contacts)
    }

    func testEventGroupLimitPreservesCPUActivationWindow() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, solverIterations: 4,
            linearDamping: 0, contactStiffness: 1, contactDamping: 0, maximumEventGroups: 1),
            broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: 0, y: 10), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 1.5, y: 10), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 3), center: .zero,
            velocity: .init(x: 0.75, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 4), center: .init(x: 3, y: 0),
            velocity: .init(x: -0.75, y: 0), mass: 1, targetRadius: 1))
        var cpu = world
        let expected = cpu.step()
        XCTAssertEqual(expected.generatedContactCount, 1)
        XCTAssertEqual(cpu.contacts.contacts.map(\.id), [.init(rawValue: 0x0000_0001_0000_0002)])
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertEqual(actual.generatedContactCount, expected.generatedContactCount)
        XCTAssertEqual(actual.didReachEventGroupLimit, expected.didReachEventGroupLimit)
        XCTAssertEqual(world.contacts.contacts.map(\.id), cpu.contacts.contacts.map(\.id))
    }

    func testSimultaneousCCDActivationOrdersBubbleAndSegmentIDsAcrossHighBit() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0,
            contactStiffness: 1, contactDamping: 0, maximumEventGroups: 1),
            broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero,
            velocity: .init(x: 0.75, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 3, y: 0),
            velocity: .init(x: -0.75, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 3), center: .init(x: 10, y: 0),
            velocity: .init(x: 1.5, y: 0), mass: 1, targetRadius: 1))
        world.addSegment(.staticSegment(id: .init(rawValue: 1),
            a: .init(x: 12, y: -3), b: .init(x: 12, y: 3)))
        var cpu = world
        let expected = cpu.step()
        XCTAssertGreaterThanOrEqual(expected.generatedContactCount, 2)
        let low = UInt64(0x0000_0001_0000_0002)
        let high = UInt64(0x8000_0003_0000_0001)
        XCTAssertEqual(cpu.contacts.contacts.map { $0.id.rawValue }, [low, high])
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertNil(runner.telemetry.fallbackReason)
        XCTAssertEqual(actual.generatedContactCount, expected.generatedContactCount)
        XCTAssertEqual(world.contacts.contacts.map { $0.id.rawValue }, [low, high])
    }

    func testCCDInsertsLowBubbleIDBeforeExistingHighSegmentID() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0,
            contactStiffness: 1, contactDamping: 0, maximumEventGroups: 1),
            broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero,
            velocity: .init(x: 0.75, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 3, y: 0),
            velocity: .init(x: -0.75, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 3), center: .init(x: 11.5, y: 0),
            mass: 1_000_000, targetRadius: 1))
        world.addSegment(.staticSegment(id: .init(rawValue: 1),
            a: .init(x: 12, y: -3), b: .init(x: 12, y: 3)))
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        for id in [1, 2] {
            var bubble = try XCTUnwrap(world.bubbles.first { $0.id.rawValue == id })
            bubble.velocity = .zero
            world.updateBubble(bubble)
        }
        var cpu = world
        _ = cpu.step()
        _ = await runner.step(world: &world, scenarioStep: 0)
        let high = UInt64(0x8000_0003_0000_0001)
        XCTAssertEqual(world.contacts.contacts.map { $0.id.rawValue }, [high])
        for id in [1, 2] {
            var bubble = try XCTUnwrap(world.bubbles.first { $0.id.rawValue == id })
            bubble.velocity = .init(x: id == 1 ? 0.75 : -0.75, y: 0)
            world.updateBubble(bubble)
            var oracleBubble = try XCTUnwrap(cpu.bubbles.first { $0.id.rawValue == id })
            oracleBubble.velocity = bubble.velocity
            cpu.updateBubble(oracleBubble)
        }
        var segmentBubble = try XCTUnwrap(world.bubbles.first { $0.id.rawValue == 3 })
        segmentBubble.center = .init(x: 11.5, y: 0)
        segmentBubble.velocity = .zero
        world.updateBubble(segmentBubble)
        var oracleSegmentBubble = try XCTUnwrap(cpu.bubbles.first { $0.id.rawValue == 3 })
        oracleSegmentBubble.center = segmentBubble.center
        oracleSegmentBubble.velocity = .zero
        cpu.updateBubble(oracleSegmentBubble)
        let expected = cpu.step()
        XCTAssertGreaterThan(expected.generatedContactCount, 0)
        let low = UInt64(0x0000_0001_0000_0002)
        XCTAssertEqual(cpu.contacts.contacts.map { $0.id.rawValue }, [low, high])
        let actual = await runner.step(world: &world, scenarioStep: 1)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertNil(runner.telemetry.fallbackReason)
        XCTAssertEqual(actual.generatedContactCount, expected.generatedContactCount)
        XCTAssertEqual(world.contacts.contacts.map { $0.id.rawValue }, [low, high])
    }

    func testOverflowingInverseDiagonalTriggersWholeFrameCPUFallback() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 1),
            broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero,
            velocity: .init(x: 1e-25, y: 0), mass: 2e38, targetRadius: 1))
        var cpu = world
        let expected = cpu.step()
        XCTAssertTrue(expected.solver.finalResidualNorm.isFinite)
        XCTAssertGreaterThan(expected.solver.finalResidualNorm, 1e13)
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertEqual(runner.telemetry.fallbackReason, "nonFiniteState")
        XCTAssertEqual(world.bubbles, cpu.bubbles)
        XCTAssertEqual(actual.solver, expected.solver)
    }

    func testStableKeyCollisionActivatesCPUScanLastWriter() async throws {
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        let ids = [1, 2, 4_294_967_297, 4_294_967_298]
        let xs: [Float] = [0, 1.5, 100, 101.5]
        for i in ids.indices {
            world.addBubble(try .init(id: .init(rawValue: ids[i]), center: .init(x: xs[i], y: 0), mass: 1, targetRadius: 1))
        }
        var cpu = world
        let expected = cpu.step()
        let cpuContact = try XCTUnwrap(cpu.contacts.contacts.first)
        XCTAssertEqual(cpu.contacts.contacts.count, 1)
        XCTAssertEqual(cpuContact.bubbleA.rawValue, 4_294_967_297)
        XCTAssertEqual(cpuContact.bubbleB?.rawValue, 4_294_967_298)
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertEqual(world.contacts.contacts.map(\.bubbleA), cpu.contacts.contacts.map(\.bubbleA))
        XCTAssertEqual(world.contacts.contacts.map(\.bubbleB), cpu.contacts.contacts.map(\.bubbleB))
        XCTAssertEqual(actual.generatedContactCount, expected.generatedContactCount)
        for (a, b) in zip(world.bubbles, cpu.bubbles) {
            XCTAssertEqual(a.center.x, b.center.x, accuracy: 0.001)
            XCTAssertEqual(a.center.y, b.center.y, accuracy: 0.001)
        }
    }

    func testStableKeyLastWriterOutsideActivationWindowMatchesCPU() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0, maximumEventGroups: 1),
            broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 1.5, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 4_294_967_297), center: .init(x: 100, y: 0),
            velocity: .init(x: 0.75, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 4_294_967_298), center: .init(x: 103, y: 0),
            velocity: .init(x: -0.75, y: 0), mass: 1, targetRadius: 1))
        var cpu = world
        let expected = cpu.step()
        XCTAssertEqual(expected.generatedContactCount, 1)
        XCTAssertEqual(cpu.contacts.contacts.map { $0.bubbleA.rawValue }, [4_294_967_297])
        let runner = ReferenceMetalWorldRunner(executor: try executor())
        let actual = await runner.step(world: &world, scenarioStep: 0)
        XCTAssertEqual(runner.telemetry.backend, .metal)
        XCTAssertEqual(actual.generatedContactCount, expected.generatedContactCount)
        XCTAssertEqual(actual.didReachEventGroupLimit, expected.didReachEventGroupLimit)
        XCTAssertEqual(world.contacts.contacts.map(\.bubbleA), cpu.contacts.contacts.map(\.bubbleA))
        XCTAssertEqual(world.contacts.contacts.map(\.bubbleB), cpu.contacts.contacts.map(\.bubbleB))
        for (a, b) in zip(world.bubbles, cpu.bubbles) {
            XCTAssertEqual(a.center.x, b.center.x, accuracy: 0.001)
        }
    }

    private func executor() throws -> ReferenceMetalSolver {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return try XCTUnwrap(ReferenceMetalSolver(device: device))
    }
}

@MainActor
private struct CorruptGPU: ReferenceMetalFrameExecuting {
    enum Corruption { case contained, render }
    let executor: ReferenceMetalSolver
    let corruption: Corruption
    func executeFrame(snapshot: ReferenceMetalSnapshot, scenarioStep: Int) async throws -> ReferenceMetalWorldFrame {
        var frame = try await executor.executeFrame(snapshot: snapshot, scenarioStep: scenarioStep)
        switch corruption {
        case .contained:
            frame.bubbles[0].center = .zero
            frame.renderData[0].x = 0
            frame.renderData[0].y = 0
        case .render: frame.renderData = []
        }
        return frame
    }
}

@MainActor
private struct FailureAfterGPU: ReferenceMetalFrameExecuting {
    let executor: ReferenceMetalSolver
    enum Failure: Error { case afterCompletion }
    func executeFrame(snapshot: ReferenceMetalSnapshot, scenarioStep: Int) async throws -> ReferenceMetalWorldFrame {
        _ = try await executor.executeFrame(snapshot: snapshot, scenarioStep: scenarioStep)
        throw Failure.afterCompletion
    }
}
