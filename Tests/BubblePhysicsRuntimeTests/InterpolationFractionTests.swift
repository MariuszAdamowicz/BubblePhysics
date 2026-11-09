@testable import BubblePhysics
import BubblePhysicsNativeMetal
import BubblePhysicsRuntime
import Metal
import XCTest

/// P-B-50, P-B-51: ułamek interpolacji i raport, czy `advance` zatwierdziło bufor z renderem.
@MainActor
final class InterpolationFractionTests: XCTestCase {
    // MARK: α = zaległość / krok, obcięte do [0, 1]

    func testFractionIsBacklogOverStep() {
        var driver = FixedStepDriver(fixedTimeStep: 0.125)
        XCTAssertEqual(driver.interpolationFraction, 0)
        XCTAssertTrue(driver.accumulate(0.03125))
        XCTAssertEqual(driver.interpolationFraction, 0.25, accuracy: 1e-12)
        XCTAssertTrue(driver.accumulate(0.0625))
        XCTAssertEqual(driver.interpolationFraction, 0.75, accuracy: 1e-12)
    }

    func testFractionIsClampedToOneWhenMoreThanAStepIsOwed() {
        var driver = FixedStepDriver(fixedTimeStep: 0.125)
        XCTAssertTrue(driver.accumulate(0.3125))
        XCTAssertEqual(driver.interpolationFraction, 1)
        driver.completeStep()
        XCTAssertEqual(driver.backlogSeconds, 0.1875, accuracy: 1e-12)
        XCTAssertEqual(driver.interpolationFraction, 1, "nadal ponad krok zaległości")
        driver.completeStep()
        XCTAssertEqual(driver.interpolationFraction, 0.5, accuracy: 1e-12)
    }

    func testFractionIsZeroWithoutBacklog() {
        var driver = FixedStepDriver(fixedTimeStep: 0.125)
        XCTAssertTrue(driver.accumulate(0.125))
        driver.completeStep()
        XCTAssertEqual(driver.interpolationFraction, 0)
    }

    // MARK: didRenderLastAdvance

    private final class NoopStepper: CompleteStepper {
        func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                          commandBuffer: MTLCommandBuffer?,
                          beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
            CompletedRuntimeStep(state: batch.state)
        }
    }

    private func makeWorld() throws -> BubbleWorld {
        BubbleWorld(configuration: try WorldConfiguration(simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]),
            fixedTimeStep: 0.125, maximumBacklog: 10), stepper: NoopStepper())
    }

    private func makeBuffer() throws -> MTLCommandBuffer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    }

    func testRenderFlagIsFalseBeforeAnyAdvanceAndAfterPlainAdvance() async throws {
        let world = try makeWorld()
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance)
        _ = await world.advance(by: 0.125)
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance, "advance bez bufora niczego nie rysuje")
    }

    func testStepFrameWithCommandBufferIsRendered() async throws {
        let world = try makeWorld()
        let command = try makeBuffer()
        var encoded = 0
        let frame = await world.advance(by: 0.125, commandBuffer: command) { encoded += 1 }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertEqual(encoded, 1)
        XCTAssertEqual(command.status, .completed)
        XCTAssertTrue(world.diagnostics.didRenderLastAdvance)
    }

    // P-B-50: klatka bez kroku też ma render; bufor zatwierdzony, krok nie wykonany, nic nie opublikowane.
    func testFrameWithoutAStepIsRenderedAndCommittedButNotPublished() async throws {
        let world = try makeWorld()
        let first = await world.advance(by: 0.125, commandBuffer: try makeBuffer()) {}
        let command = try makeBuffer()
        var encoded = 0
        let frame = await world.advance(by: 0.0625, commandBuffer: command) { encoded += 1 }
        XCTAssertEqual(frame, first, "bez publikacji lastFrame bez zmian")
        XCTAssertEqual(encoded, 1)
        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(world.diagnostics.stepsInLastAdvance, 0)
        XCTAssertTrue(world.diagnostics.didRenderLastAdvance)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.0625, accuracy: 1e-12, "czas dalej czeka na krok")
    }

    // P-B-51: zaległość ponad krok — jeden krok na bufor, reszta w diagnostyce.
    func testBacklogOverAStepRunsOneStepAndReportsTheRest() async throws {
        let world = try makeWorld()
        let command = try makeBuffer()
        let frame = await world.advance(by: 0.3125, commandBuffer: command) {}
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertEqual(world.diagnostics.stepsInLastAdvance, 1)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.1875, accuracy: 1e-12)
        XCTAssertTrue(world.diagnostics.didRenderLastAdvance)
    }

    func testPausedWorldDoesNotRenderAndLeavesBufferUncommitted() async throws {
        let world = try makeWorld()
        world.pause()
        let command = try makeBuffer()
        var encoded = 0
        _ = await world.advance(by: 0.125, commandBuffer: command) { encoded += 1 }
        XCTAssertEqual(encoded, 0)
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance)
    }

    func testRejectedFrameAndInvalidTimeDoNotCountAsRendered() async throws {
        struct GameError: Error {}
        let world = try makeWorld()
        _ = await world.advance(by: 0.125, commandBuffer: try makeBuffer()) {}
        XCTAssertTrue(world.diagnostics.didRenderLastAdvance)
        _ = await world.advance(by: 0.0625, commandBuffer: try makeBuffer()) { throw GameError() }
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance, "błąd kodowania renderu w klatce bez kroku")
        _ = await world.advance(by: 0.125, commandBuffer: try makeBuffer()) {}
        XCTAssertTrue(world.diagnostics.didRenderLastAdvance)
        let command = try makeBuffer()
        _ = await world.advance(by: -1, commandBuffer: command) {}
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance)
    }

    func testRenderEncodingErrorInAStepFrameDoesNotCountAsRendered() async throws {
        struct GameError: Error {}
        let world = try makeWorld()
        let frame = await world.advance(by: 0.125, commandBuffer: try makeBuffer()) { throw GameError() }
        XCTAssertEqual(frame.stepIndex, 0)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance)
        XCTAssertNil(world.diagnostics.failureReason)
    }
}
