import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalSafetyTests: XCTestCase {
    func testDiagnosticRunnerPreservesSuccessfulGPUFrameTelemetry() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: -0.75)
        world.addSegment(wall())
        _ = try await solver.executeFrame(world: world, scenarioStep: 1)
        var bubble = world.bubbles[0]; bubble.velocity.x = 1.5; world.updateBubble(bubble)
        var cpu = world; let expected = cpu.step()
        let runner = NativeMetalWorldRunner(executor: solver)
        let actual = await runner.step(world: &world, scenarioStep: 2)
        let gpu = try XCTUnwrap(solver.publishedFrame)
        XCTAssertEqual(world.bubbles, cpu.bubbles)
        XCTAssertEqual(world.contacts, cpu.contacts)
        XCTAssertEqual(actual.solver, expected.solver)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertEqual(runner.telemetry.fallbackReason, "invalidFrame")
        XCTAssertGreaterThan(gpu.telemetry.ccdCandidateCount, 0)
        XCTAssertGreaterThan(gpu.telemetry.guardCorrectionCount, 0)
        XCTAssertGreaterThan(gpu.telemetry.cacheInvalidationCount, 0)
        XCTAssertEqual(runner.telemetry.ccdCandidateCount, gpu.telemetry.ccdCandidateCount)
        XCTAssertEqual(runner.telemetry.guardCorrectionCount, gpu.telemetry.guardCorrectionCount)
        XCTAssertEqual(runner.telemetry.cacheInvalidationCount, gpu.telemetry.cacheInvalidationCount)
        XCTAssertEqual(runner.telemetry.cacheResetCount, gpu.telemetry.cacheResetCount)
        XCTAssertEqual(runner.telemetry.commandBufferCount, 1)
        XCTAssertEqual(runner.telemetry.encoderCount, 2)
        XCTAssertEqual(runner.telemetry.gpuMilliseconds, gpu.telemetry.gpuMilliseconds)
        XCTAssertEqual(runner.profile, gpu.profile)
    }

    func testDistantSlowPairsExecuteNoAnalyticCCDInAnyStage() async throws {
        var world = try makeWorld(x: -4, vx: 0.25)
        for i in 0..<32 {
            world.addSegment(.staticSegment(id: .init(rawValue: i + 1), a: .init(x: Float(i + 10), y: -10),
                b: .init(x: Float(i + 10), y: 10)))
        }
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), collectDispatchStatistics: true)
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.telemetry.ccdCandidateCount, 0)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["ccdAnalyticTests"] ?? -1, 0)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["guardAnalyticTests"] ?? -1, 0)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["ccdFinitePathTests"] ?? -1, 0)
        XCTAssertEqual(frame.bubbles[0].center.x, -3.75, accuracy: 0.00001)
    }

    func testFastBubbleDoesNotCrossSegmentCenter() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), collectDispatchStatistics: true)
        var world = try makeWorld(x: -4, vx: 10)
        world.addSegment(wall())
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertLessThan(frame.bubbles[0].center.x, 0)
        XCTAssertGreaterThan(frame.report.toiTestCount, 0)
        XCTAssertEqual(frame.profile.commandBufferCount, 1)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["ccdAnalyticTests"], 1)
    }

    func testMovingPolygonCannotContainBubbleCenter() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: 0)
        let vertices: [ReferenceVector2] = [.init(x: -2, y: -2), .init(x: 2, y: -2),
                                         .init(x: 2, y: 2), .init(x: -2, y: 2)]
        for index in vertices.indices {
            let a = vertices[index], b = vertices[(index + 1) % vertices.count]
            world.addSegment(.kinematicSegment(id: .init(rawValue: index + 1),
                previousA: a + .init(x: -8, y: 0), previousB: b + .init(x: -8, y: 0),
                currentA: a, currentB: b, timeStep: 1, ownerID: 7))
        }
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        let p = frame.bubbles[0].center
        XCTAssertFalse(p.x > -2 && p.x < 2 && p.y > -2 && p.y < 2)
        XCTAssertGreaterThan(frame.report.sideCorrectionCount, 0)
    }

    func testCCDInvalidatesIncidentWarmStart() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: -0.75)
        world.addSegment(wall())
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 10, y: 30), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 3), center: .init(x: 11.5, y: 30), mass: 1, targetRadius: 1))
        _ = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertGreaterThan(try XCTUnwrap(solver.cachedContacts.first { $0.key == .bubbleSegment(1, 1) }).lambda, 0)
        var bubble = world.bubbles[0]
        bubble.velocity.x = 1.5
        world.updateBubble(bubble)
        let frame = try await solver.executeFrame(snapshot: .init(world: world), scenarioStep: 2)
        XCTAssertLessThan(frame.bubbles[0].center.x, 0)
        let cache = try XCTUnwrap(solver.cachedContacts.first { $0.key == .bubbleSegment(1, 1) })
        XCTAssertEqual(cache.lambda, 0)
        XCTAssertNotEqual(cache.flags & 8, 0)
        XCTAssertGreaterThan(frame.report.toiTestCount, 0)
        let independent = try XCTUnwrap(solver.cachedContacts.first { $0.key == .bubblePair(2, 3) })
        XCTAssertEqual(independent.lambda, 0.25, accuracy: 0.00001)
        XCTAssertEqual(independent.flags & 8, 0)
        XCTAssertEqual(frame.telemetry.cacheInvalidationCount, 1)
    }

    func testNonFiniteCandidateFallsBackWithoutPublication() async throws {
        let executor = SafetyCorruptingCommandExecutor()
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), commandExecutor: executor)
        var world = try makeWorld(x: -4, vx: 1)
        let first = try await solver.executeFrame(world: world, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let published = state.publishedBubbles
        executor.corrupt = {
            var value = state.workingBubbles.contents().load(as: NativeMetalBubble.self)
            value.motion.x = .nan
            state.workingBubbles.contents().storeBytes(of: value, as: NativeMetalBubble.self)
        }
        var cpu = world
        _ = cpu.step()
        let runner = NativeMetalWorldRunner(executor: solver)
        _ = await runner.step(world: &world, scenarioStep: 2)
        XCTAssertEqual(world.bubbles, cpu.bubbles)
        XCTAssertEqual(world.contacts, cpu.contacts)
        XCTAssertEqual(solver.publishedFrame?.bubbles, first.bubbles)
        XCTAssertTrue(state.publishedBubbles === published)
        XCTAssertTrue(runner.telemetry.didEncounterNonFinite)
        XCTAssertEqual(runner.telemetry.fallbackReason, "nonFinite")
    }

    func testGuardFailureRerunsCPUFromOriginalWorld() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: 0.5, vx: 0.1)
        let first = try await solver.executeFrame(world: world, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let published = state.publishedBubbles
        // Niespójne półprzestrzenie: x <= 0 oraz x >= 1.
        world.addSegment(wall(mode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 1, y: -10),
            b: .init(x: 1, y: 10), collisionMode: .oneSided(allowedSide: -1)))
        var cpu = world
        let expected = cpu.step()
        let runner = NativeMetalWorldRunner(executor: solver)
        let actual = await runner.step(world: &world, scenarioStep: 2)
        XCTAssertEqual(world.bubbles, cpu.bubbles)
        XCTAssertEqual(world.contacts, cpu.contacts)
        XCTAssertEqual(actual.solver, expected.solver)
        XCTAssertEqual(solver.publishedFrame?.bubbles, first.bubbles)
        XCTAssertTrue(state.publishedBubbles === published)
        XCTAssertEqual(runner.telemetry.fallbackReason, "guardFailure")
    }

    func testSlowMotionDoesNotRunCCD() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: -4, vx: 0.25)
        world.addSegment(wall())
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.report.toiTestCount, 0)
        XCTAssertEqual(frame.bubbles[0].center.x, -3.75, accuracy: 0.00001)
    }

    func testInitiallyContainedCenterCanEscapePolygon() async throws {
        var world = try makeWorld(x: 0)
        let vertices: [ReferenceVector2] = [.init(x: -2, y: -2), .init(x: 2, y: -2),
                                         .init(x: 2, y: 2), .init(x: -2, y: 2)]
        for i in vertices.indices {
            world.addSegment(.staticSegment(id: .init(rawValue: i + 1), a: vertices[i],
                b: vertices[(i + 1) % 4], ownerID: 7))
        }
        let solver = try makeSolver()
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        let p = frame.bubbles[0].center
        XCTAssertFalse(p.x > -2 && p.x < 2 && p.y > -2 && p.y < 2)
        XCTAssertGreaterThan(frame.report.sideCorrectionCount, 0)
    }

    func testFiniteGeometryOverflowRejectsCandidate() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: 0, y: 2)
        let first = try await solver.executeFrame(world: world, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let published = state.publishedBubbles
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: -1e30, y: 0), b: .init(x: 1e30, y: 0)))
        do {
            _ = try await solver.executeFrame(world: world, scenarioStep: 2)
            XCTFail("Nieskończona geometria pośrednia musi odrzucić klatkę")
        } catch let failure as NativeMetalSafetyFailure {
            XCTAssertEqual(String(describing: failure.reason), "nonFinite")
            XCTAssertTrue(failure.telemetry.didEncounterNonFinite)
        }
        XCTAssertTrue(state.publishedBubbles === published)
        XCTAssertEqual(solver.publishedFrame?.bubbles, first.bubbles)
        XCTAssertNotEqual(state.safetyControl.contents().load(as: NativeMetalSafetyControl.self).counts.w & 1, 0)
    }

    func testGPUFiniteGuardRejectsNaNWithoutPublishing() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: -4)
        _ = try await solver.executeFrame(world: world, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let published = state.publishedBubbles
        var bubble = world.bubbles[0]; bubble.velocity.x = .nan; world.updateBubble(bubble)
        do {
            _ = try await solver.executeFrame(world: world, scenarioStep: 2)
            XCTFail("GPU musi zapisać naruszenie finite do bufora kontrolnego")
        } catch let failure as NativeMetalSafetyFailure {
            XCTAssertEqual(String(describing: failure.reason), "nonFinite")
        }
        XCTAssertTrue(state.publishedBubbles === published)
        XCTAssertNotEqual(state.safetyControl.contents().load(as: NativeMetalSafetyControl.self).counts.w & 1, 0)
    }

    func testCCDThresholdUsesConfiguredMultiplierAndRadius() async throws {
        var world = try makeWorld(x: -4, vx: 10)
        world.addSegment(wall())
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(ccdVelocityMultiplier: 20))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.telemetry.ccdCandidateCount, 0)
        XCTAssertLessThan(frame.bubbles[0].center.x, 0)
        XCTAssertGreaterThan(frame.telemetry.guardCorrectionCount, 0)
    }

    func testRotatingSegmentLeavesNoCenterCrossingInPublishedFrame() async throws {
        var world = try makeWorld(x: 0, y: 2)
        world.addSegment(.kinematicSegment(id: .init(rawValue: 1), previousA: .init(x: -4, y: 0),
            previousB: .init(x: 4, y: 0), currentA: .init(x: 0, y: -4), currentB: .init(x: 0, y: 4),
            timeStep: 1, collisionMode: .oneSided(allowedSide: 1)))
        let solver = try makeSolver()
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertLessThan(frame.bubbles[0].center.x, 0)
        XCTAssertGreaterThan(frame.telemetry.ccdCandidateCount, 0)
        XCTAssertTrue(frame.bubbles[0].center.isFinite)
    }

    func testCollinearMovingSegmentCannotPassThroughCenter() async throws {
        var world = try makeWorld(x: 0)
        world.addSegment(.kinematicSegment(id: .init(rawValue: 1), previousA: .init(x: -4, y: 0),
            previousB: .init(x: -2, y: 0), currentA: .init(x: 2, y: 0), currentB: .init(x: 4, y: 0),
            timeStep: 1, collisionMode: .oneSided(allowedSide: 1)))
        let solver = try makeSolver()
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertGreaterThan(frame.bubbles[0].center.y, 0)
        XCTAssertEqual(frame.telemetry.ccdCandidateCount, 1)
        XCTAssertGreaterThan(frame.telemetry.guardCorrectionCount, 0)
    }

    func testCollinearBubbleCannotPassAlongStaticSegment() async throws {
        var world = try makeWorld(x: -4, vx: 10)
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 2, y: 0)))
        let solver = try makeSolver()
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertGreaterThan(abs(frame.bubbles[0].center.y), 0)
        XCTAssertEqual(frame.telemetry.ccdCandidateCount, 1)
        XCTAssertGreaterThan(frame.telemetry.guardCorrectionCount, 0)
    }

    func testSlowCrossingStillReceivesCenterGuard() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), collectDispatchStatistics: true)
        var world = try makeWorld(x: -0.05, vx: 0.1)
        world.addSegment(wall())
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.report.toiTestCount, 0)
        XCTAssertLessThan(frame.bubbles[0].center.x, 0)
        XCTAssertGreaterThan(frame.report.sideCorrectionCount, 0)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["ccdAnalyticTests"], 0)
        XCTAssertEqual(frame.profile.stageGPUWorkItemCounts["guardAnalyticTests"], 1)
    }

    func testTrajectoryOutsideSegmentEndpointsIsNotClamped() async throws {
        let solver = try makeSolver()
        var world = try makeWorld(x: -4, y: 20, vx: 10)
        world.addSegment(wall())
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(frame.bubbles[0].center.x, 6, accuracy: 0.00001)
        XCTAssertEqual(frame.report.sideCorrectionCount, 0)
    }

    private func makeSolver() throws -> NativeMetalSolver {
        try .init(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }

    private func makeWorld(x: Float, y: Float = 0, vx: Float = 0) throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0, angularDamping: 0),
                                   broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: x, y: y),
            velocity: .init(x: vx, y: 0), mass: 1, targetRadius: 1))
        return world
    }

    private func wall(mode: ReferenceSegmentCollisionMode = .twoSided) -> ReferenceSegment {
        .staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -10), b: .init(x: 0, y: 10), collisionMode: mode)
    }
}

@MainActor
private final class SafetyCorruptingCommandExecutor: NativeMetalCommandExecuting {
    var corrupt: (() -> Void)?
    func complete(_ command: MTLCommandBuffer) async throws -> NativeMetalCommandTiming {
        let timing = try await NativeMetalCommandExecutor().complete(command)
        corrupt?()
        corrupt = nil
        return timing
    }
}
