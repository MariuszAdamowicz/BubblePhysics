import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalSolverLifecycleTests: XCTestCase {
    func testStressRunnerKeepsThreeHundredPublishedBubblesOnGPU() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let runner = NativeMetalWorldRunner(executor: solver)
        let scenario = ReferenceConvergenceScenario(scene: .stress300, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()
        for step in 0..<3 {
            scenario.updatePolygon(in: &world, fromStep: step, toStep: step + 1)
            _ = await runner.step(world: &world, scenarioStep: step)
            XCTAssertNil(runner.telemetry.fallbackReason)
            XCTAssertEqual(runner.profile.bubbleUploadCount, step == 0 ? 300 : 0)
            XCTAssertEqual(world.bubbles.count, 300)
            XCTAssertEqual(runner.profile.commandBufferCount, 1)
        }
    }

    func testAcknowledgedPublicationKeepsInsertRemoveAndResetEditsDistinctFromGPUProgress() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let runner = NativeMetalWorldRunner(executor: solver)
        var world = try makeWorld()
        _ = await runner.step(world: &world, scenarioStep: 1)
        // Cofnięcie do oryginalnej pozycji jest rzeczywistą edycją, mimo że
        // identyczne wejście bezpośredniego solvera oznacza kontynuację GPU.
        world.updateBubble(try makeWorld().bubbles[0])
        _ = await runner.step(world: &world, scenarioStep: 2)
        XCTAssertEqual(runner.profile.bubbleUploadCount, 1)
        XCTAssertEqual(world.bubbles[0].center.x, 0.5)
        world.addBubble(try .init(id: .init(rawValue: 0), center: .init(x: -10, y: 0), mass: 1, targetRadius: 1))
        _ = await runner.step(world: &world, scenarioStep: 3)
        XCTAssertEqual(runner.profile.bubbleUploadCount, 1)
        XCTAssertEqual(world.bubbles[1].center.x, 1)
        var reduced = ReferenceWorld(configuration: world.configuration, broadPhase: BruteForceBroadPhase())
        reduced.addBubble(world.bubbles[1])
        _ = await runner.step(world: &reduced, scenarioStep: 4)
        XCTAssertEqual(runner.profile.bubbleUploadCount, 0)
        XCTAssertEqual(reduced.bubbles[0].center.x, 1.5)
        XCTAssertNil(runner.telemetry.fallbackReason)
    }

    // Własna publikacja GPU nie może być ponownie traktowana jako edycja gry.
    func testPublishedGPUStateNeedsNoBubbleUploadsButExternalEditDoes() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let runner = NativeMetalWorldRunner(executor: solver)
        var world = try makeWorld()
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 10, y: 0),
            velocity: .init(x: 2, y: 0), mass: 1, targetRadius: 1))
        _ = await runner.step(world: &world, scenarioStep: 1)
        XCTAssertEqual(runner.profile.bubbleUploadCount, 2)
        for step in 2...4 {
            _ = await runner.step(world: &world, scenarioStep: step)
            XCTAssertNil(runner.telemetry.fallbackReason)
            XCTAssertEqual(runner.profile.bubbleUploadCount, 0)
        }
        XCTAssertEqual(world.bubbles[0].center.x, 2, accuracy: 1e-6)
        var edited = world.bubbles[0]
        edited.center.x = 100
        edited.previousCenter.x = 100
        world.updateBubble(edited)
        _ = await runner.step(world: &world, scenarioStep: 5)
        XCTAssertEqual(runner.profile.bubbleUploadCount, 1)
        XCTAssertEqual(world.bubbles[0].center.x, 100.5, accuracy: 1e-6)
        XCTAssertEqual(world.bubbles[1].center.x, 12.5, accuracy: 1e-6)
        _ = await runner.step(world: &world, scenarioStep: 6)
        XCTAssertEqual(runner.profile.bubbleUploadCount, 0)
        XCTAssertEqual(world.bubbles[0].center.x, 101, accuracy: 1e-6)
    }

    func testTwoFramesReusePersistentBuffers() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let solver = try NativeMetalSolver(device: device)
        let firstInput = NativeMetalSnapshot(world: try makeWorld())
        let first = try await solver.executeFrame(snapshot: firstInput, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let ping = state.bubblesPing
        let pong = state.bubblesPong
        let cache = state.cachePing
        let scratch = state.scratch
        let secondInput = NativeMetalSnapshot(world: try makeWorld(), previous: firstInput)
        XCTAssertTrue(secondInput.bubbleChanges.isEmpty)
        let second = try await solver.executeFrame(snapshot: secondInput, scenarioStep: 2)
        XCTAssertTrue(solver.persistentState === state)
        XCTAssertTrue(state.bubblesPing === ping)
        XCTAssertTrue(state.bubblesPong === pong)
        XCTAssertTrue(state.cachePing === cache)
        XCTAssertTrue(state.scratch === scratch)
        XCTAssertEqual(first.bubbles[0].center.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(second.bubbles[0].center.x, 1, accuracy: 1e-6)
        XCTAssertEqual(second.bubbles[0].previousCenter.x, 0.5, accuracy: 1e-6)
    }

    func testAddingLowerIDPreservesExistingBubbleGPUProgress() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var world = ReferenceWorld(configuration: .init(timeStep: 0.25, linearDamping: 0, angularDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 10, y: 0),
            velocity: .init(x: 2, y: 0), mass: 1, targetRadius: 1))
        let firstInput = NativeMetalSnapshot(world: world)
        let first = try await solver.executeFrame(snapshot: firstInput, scenarioStep: 1)
        XCTAssertEqual(first.bubbles[0].center.x, 10.5, accuracy: 1e-6)
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 1))
        let nextInput = NativeMetalSnapshot(world: world, previous: firstInput)
        XCTAssertEqual(nextInput.bubbleChanges.map { $0.value.identity.x }, [1])
        let second = try await solver.executeFrame(snapshot: nextInput, scenarioStep: 2)
        let existing = try XCTUnwrap(second.bubbles.first { $0.id.rawValue == 2 })
        XCTAssertEqual(existing.center.x, 11, accuracy: 1e-6)
        XCTAssertEqual(existing.previousCenter.x, 10.5, accuracy: 1e-6)
        XCTAssertEqual(second.profile.commandBufferCount, 1)
    }

    func testNormalFrameUsesExactlyOneCommandBuffer() async throws {
        let executor = ControlledCommandExecutor()
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), commandExecutor: executor)
        let frame = try await solver.executeFrame(snapshot: .init(world: try makeWorld()), scenarioStep: 7)
        XCTAssertEqual(executor.submissionStatuses, [.notEnqueued])
        XCTAssertEqual(executor.commitCount, 1)
        XCTAssertEqual(frame.profile.commandBufferCount, 1)
        XCTAssertEqual(frame.profile.encoderCount, 2)
        XCTAssertGreaterThanOrEqual(frame.profile.hostEncodingMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(frame.profile.hostWaitingMilliseconds, 0)
        XCTAssertEqual(frame.profile.stageGPUMilliseconds.keys.sorted(), ["frame"])
        XCTAssertTrue(frame.isComplete)
    }

    func testFailedCommandDoesNotReplacePublishedState() async throws {
        let executor = ControlledCommandExecutor()
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), commandExecutor: executor)
        let firstInput = NativeMetalSnapshot(world: try makeWorld())
        let first = try await solver.executeFrame(snapshot: firstInput, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let publishedBuffer = state.publishedBubbles
        executor.failNext = true
        do {
            _ = try await solver.executeFrame(snapshot: .init(world: try makeWorld(), previous: firstInput), scenarioStep: 2)
            XCTFail("Oczekiwany błąd ukończonego polecenia")
        } catch ControlledCommandExecutor.Failure.injected {}
        XCTAssertTrue(solver.persistentState === state)
        XCTAssertTrue(state.publishedBubbles === publishedBuffer)
        XCTAssertEqual(solver.publishedFrame?.bubbles, first.bubbles)
        let recovered = try await solver.executeFrame(snapshot: .init(world: try makeWorld(), previous: firstInput), scenarioStep: 3)
        XCTAssertEqual(recovered.bubbles[0].center.x, 1, accuracy: 1e-6)
    }

    func testCapacityGrowthPreservesPublishedPrediction() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let initial = NativeMetalSnapshot(world: try makeWorld())
        _ = try await solver.executeFrame(snapshot: initial, scenarioStep: 1)
        var larger = try makeWorld()
        for id in 2...20 {
            larger.addBubble(try .init(id: .init(rawValue: id), center: .init(x: Float(id * 10), y: 0), mass: 1, targetRadius: 1))
        }
        let input = NativeMetalSnapshot(world: larger, previous: initial)
        XCTAssertEqual(input.bubbleChanges.count, 19)
        let frame = try await solver.executeFrame(snapshot: input, scenarioStep: 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(solver.persistentState).bubbleCapacity, 20)
        XCTAssertEqual(frame.bubbles[0].center.x, 1, accuracy: 1e-6)
        XCTAssertEqual(frame.bubbles.count, 20)
    }

    func testFailedCommandDoesNotReplacePublishedSegmentInput() async throws {
        let executor = ControlledCommandExecutor()
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), commandExecutor: executor)
        var world = try makeWorld()
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .zero, b: .init(x: 5, y: 0)))
        let first = NativeMetalSnapshot(world: world)
        _ = try await solver.executeFrame(snapshot: first, scenarioStep: 1)
        let state = try XCTUnwrap(solver.persistentState)
        let publishedSegments = state.segments
        world.updateSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 100, y: 0), b: .init(x: 105, y: 0)))
        executor.failNext = true
        do {
            _ = try await solver.executeFrame(snapshot: .init(world: world, previous: first), scenarioStep: 2)
            XCTFail("Oczekiwany błąd polecenia")
        } catch ControlledCommandExecutor.Failure.injected {}
        XCTAssertTrue(state.segments === publishedSegments)
        let record = state.segments.contents().load(as: NativeMetalSegment.self)
        XCTAssertEqual(record.current.x, 0)
        XCTAssertEqual(record.current.z, 5)
    }

    func testStaleDeltaSnapshotIsRejectedBeforeCommit() async throws {
        let executor = ControlledCommandExecutor()
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), commandExecutor: executor)
        var world = try makeWorld()
        let first = NativeMetalSnapshot(world: world)
        _ = try await solver.executeFrame(snapshot: first, scenarioStep: 1)
        var changed = world.bubbles[0]
        changed.center.x = 100
        world.updateBubble(changed)
        _ = try await solver.executeFrame(snapshot: .init(world: world, previous: first), scenarioStep: 2)
        let published = solver.publishedFrame?.bubbles
        do {
            _ = try await solver.executeFrame(snapshot: .init(world: try makeWorld(), previous: first), scenarioStep: 3)
            XCTFail("Nieaktualna baza delta musi być odrzucona")
        } catch NativeMetalSolverError.invalidSnapshot {}
        XCTAssertEqual(executor.commitCount, 2)
        XCTAssertEqual(solver.publishedFrame?.bubbles, published)
    }

    func testChangedCPUInputIsAppliedWithoutResettingOtherBubbles() async throws {
        var world = try makeWorld()
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 10, y: 0), velocity: .init(x: 2, y: 0), mass: 1, targetRadius: 1))
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let first = NativeMetalSnapshot(world: world)
        _ = try await solver.executeFrame(snapshot: first, scenarioStep: 1)
        var moved = world.bubbles[0]
        moved.center.x = 100
        world.updateBubble(moved)
        let second = NativeMetalSnapshot(world: world, previous: first)
        XCTAssertEqual(second.bubbleChanges.count, 1)
        let frame = try await solver.executeFrame(snapshot: second, scenarioStep: 2)
        XCTAssertEqual(frame.bubbles[0].center.x, 100.5, accuracy: 1e-6)
        XCTAssertEqual(frame.bubbles[1].center.x, 11, accuracy: 1e-6)
    }

    func testGrowingSegmentsDoesNotShrinkBubbleCapacity() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var large = try makeWorld()
        for id in 2...20 {
            large.addBubble(try .init(id: .init(rawValue: id), center: .init(x: Float(id * 10), y: 0), mass: 1, targetRadius: 1))
        }
        let first = NativeMetalSnapshot(world: large)
        _ = try await solver.executeFrame(snapshot: first, scenarioStep: 1)
        let originalCapacity = try XCTUnwrap(solver.persistentState).bubbleCapacity
        var smaller = try makeWorld()
        for id in 1...20 {
            smaller.addSegment(.staticSegment(id: .init(rawValue: id), a: .init(x: Float(id), y: -10), b: .init(x: Float(id), y: -5)))
        }
        _ = try await solver.executeFrame(snapshot: .init(world: smaller, previous: first), scenarioStep: 2)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(solver.persistentState).bubbleCapacity, originalCapacity)
    }

    func testABIRecordsUseSixteenByteLanes() {
        XCTAssertEqual(MemoryLayout<NativeMetalBubble>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NativeMetalBubble>.stride, 144)
        XCTAssertEqual(MemoryLayout<NativeMetalEventRecord>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NativeMetalEventRecord>.stride, 48)
        XCTAssertEqual(MemoryLayout<NativeMetalSensorRecord>.stride, 48)
        XCTAssertEqual(MemoryLayout<NativeMetalSensorPair>.stride, 32)
        XCTAssertEqual(MemoryLayout<NativeMetalSegment>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NativeMetalSegment>.stride, 96)
        XCTAssertEqual(MemoryLayout<NativeMetalContactCache>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NativeMetalContactCache>.stride, 64)
        XCTAssertEqual(MemoryLayout<NativeMetalCandidate>.stride, 32)
        XCTAssertEqual(MemoryLayout<NativeMetalGridEntry>.stride, 32)
        XCTAssertEqual(MemoryLayout<NativeMetalContactControl>.stride, 80)
        XCTAssertEqual(MemoryLayout<NativeMetalControl>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NativeMetalControl>.stride, 64)
        XCTAssertEqual(MemoryLayout<NativeMetalSolverControl>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NativeMetalSolverControl>.stride, 32)
        XCTAssertEqual(MemoryLayout<NativeMetalRenderPacket>.alignment, 16)
        XCTAssertEqual(MemoryLayout<NativeMetalRenderPacket>.stride, 48)
    }

    func testCompleteRunnerPublishesGPUFrameAndExposesProfile() async throws {
        var world = try makeWorld()
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 1.5, y: 0), mass: 1, targetRadius: 1))
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let runner = NativeMetalWorldRunner(executor: solver)
        for step in 1...2 {
            let actual = await runner.step(world: &world, scenarioStep: step)
            let frame = try XCTUnwrap(solver.publishedFrame)
            XCTAssertEqual(world.bubbles, frame.bubbles)
            XCTAssertEqual(world.contacts.contacts, frame.contacts)
            XCTAssertEqual(actual.solver, frame.report.solver)
            XCTAssertEqual(runner.contours, frame.contours)
            XCTAssertEqual(runner.renderData, frame.renderData)
            XCTAssertEqual(runner.telemetry.backend, .nativeMetal)
            XCTAssertNil(runner.telemetry.fallbackReason)
            XCTAssertEqual(runner.profile.commandBufferCount, 1)
            XCTAssertEqual(runner.profile.encoderCount, 2)
        }
    }

    private func makeWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(timeStep: 0.25, linearDamping: 0, angularDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, velocity: .init(x: 2, y: 0), mass: 1, targetRadius: 1))
        return world
    }
}

@MainActor
private final class ControlledCommandExecutor: NativeMetalCommandExecuting {
    enum Failure: Error { case injected }
    var failNext = false
    var commitCount = 0
    var submissionStatuses: [MTLCommandBufferStatus] = []

    func complete(_ command: MTLCommandBuffer) async throws -> NativeMetalCommandTiming {
        submissionStatuses.append(command.status)
        commitCount += 1
        let timing = try await NativeMetalCommandExecutor().complete(command)
        if failNext {
            failNext = false
            throw Failure.injected
        }
        return timing
    }
}
