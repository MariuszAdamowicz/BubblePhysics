import BubblePhysics
import XCTest

@MainActor
final class BubbleWorldTimeTests: XCTestCase {
    private func world(step: Double = 0.125) throws -> BubbleWorld {
        try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: step), device: nil)
    }

    func testAdvanceAccumulatesPresentationTimeIntoDeterministicFixedSteps() async throws {
        let world = try world()
        let initial = await world.advance(by: 0.0625)
        XCTAssertEqual(initial.stepIndex, 0)
        XCTAssertEqual(initial.simulationTime, 0)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.0625)
        let frame = await world.advance(by: 0.3125)
        XCTAssertEqual(frame.stepIndex, 3)
        XCTAssertEqual(frame.simulationTime, 0.375)
        XCTAssertEqual(world.diagnostics.stepsInLastAdvance, 3)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0)
        let split = try self.world()
        _ = await split.advance(by: 0.125)
        _ = await split.advance(by: 0.125)
        let splitFrame = await split.advance(by: 0.125)
        XCTAssertEqual(splitFrame, frame)
    }

    func testOneSecondBatchAndSixtyPresentationIntervalsCompleteSameSixtySteps() async throws {
        let batched = try world(step: 1.0 / 60.0)
        var batchedFrame = await batched.advance(by: 1)
        for _ in 0..<8 { batchedFrame = await batched.advance(by: 0) }

        let split = try world(step: 1.0 / 60.0)
        var splitFrame = await split.advance(by: 0)
        for _ in 0..<60 { splitFrame = await split.advance(by: 1.0 / 60.0) }

        XCTAssertEqual(batchedFrame.stepIndex, 60)
        XCTAssertEqual(splitFrame.stepIndex, 60)
        XCTAssertEqual(batched.diagnostics.backlogSeconds, 0, accuracy: 1e-12)
        XCTAssertEqual(split.diagnostics.backlogSeconds, 0, accuracy: 1e-12)
    }

    func testTransactionsPublishOnlyAtFixedStepBoundary() async throws {
        let world = try world()
        let token = world.submit(WorldTransaction().setGlobalForce([0, -3]))
        let partial = await world.advance(by: 0.0625)
        XCTAssertTrue(partial.transactionReceipts.isEmpty)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        let complete = await world.advance(by: 0.0625)
        XCTAssertEqual(complete.transactionReceipts.map(\.token), [token])
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 0)
        let unchanged = await world.advance(by: 0)
        XCTAssertEqual(unchanged, complete)
        let next = await world.advance(by: 0.125)
        XCTAssertTrue(next.transactionReceipts.isEmpty)
    }

    func testMultipleStepsPreserveAllOrderedReceiptsAndRejections() async throws {
        let world = try world()
        let first = world.submit(WorldTransaction().setGlobalForce([1, 0]))
        let rejected = world.submit(WorldTransaction().remove(ObjectID(rawValue: 42)))
        let last = world.submit(WorldTransaction().setGlobalForce([2, 0]))
        XCTAssertNotEqual(first, rejected)
        XCTAssertNotEqual(rejected, last)
        let frame = await world.advance(by: 0.375)
        XCTAssertEqual(frame.stepIndex, 3)
        XCTAssertEqual(frame.transactionReceipts.map(\.token), [first, last])
        XCTAssertEqual(frame.events, [.transactionRejected(rejected,
            TransactionRejection(operationIndex: 0, reason: .objectNotFound(ObjectID(rawValue: 42))))])
    }

    func testPausePreventsStepsButKeepsQueuedTransaction() async throws {
        let world = try world()
        let beforePause = await world.advance(by: 0.0625)
        world.pause()
        world.pause()
        let token = world.submit(WorldTransaction().setGlobalForce([1, 2]))
        let paused = await world.advance(by: 60)
        XCTAssertEqual(paused, beforePause)
        XCTAssertTrue(world.diagnostics.isPaused)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.0625)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        world.resume()
        world.resume()
        let resumed = await world.advance(by: 0.0625)
        XCTAssertEqual(resumed.stepIndex, 1)
        XCTAssertEqual(resumed.transactionReceipts.map(\.token), [token])
        XCTAssertFalse(world.diagnostics.isPaused)
    }

    func testPersistentBacklogCanBeDrainedWithoutChangingConfiguredStep() async throws {
        let world = try world()
        let first = await world.advance(by: 100)
        XCTAssertGreaterThan(first.stepIndex, 0)
        XCTAssertLessThan(first.simulationTime, 100)
        XCTAssertEqual(first.simulationTime + world.diagnostics.backlogSeconds, 100)
        XCTAssertEqual(world.diagnostics.consecutiveBackloggedAdvances, 1)
        let second = await world.advance(by: 100)
        XCTAssertEqual(second.simulationTime + world.diagnostics.backlogSeconds, 200)
        XCTAssertEqual(world.diagnostics.consecutiveBackloggedAdvances, 2)
        var final = second
        while world.diagnostics.backlogSeconds >= 0.125 {
            final = await world.advance(by: 0)
        }
        XCTAssertEqual(final.stepIndex, 1600)
        XCTAssertEqual(final.simulationTime, 200)
        XCTAssertEqual(world.configuration.fixedTimeStep, 0.125)
        XCTAssertEqual(world.diagnostics.consecutiveBackloggedAdvances, 0)
    }

    func testInvalidTimeIsReportedWithoutConsumingTimeOrTransactions() async throws {
        let world = try world()
        let initial = await world.advance(by: 0.0625)
        let token = world.submit(WorldTransaction())
        for invalid in [-1, Double.nan, .infinity, -.infinity] {
            let frame = await world.advance(by: invalid)
            XCTAssertEqual(frame, initial)
            XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .invalidTimeDelta)
            XCTAssertEqual(world.diagnostics.backlogSeconds, 0.0625)
            XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        }
        let valid = await world.advance(by: 0.0625)
        XCTAssertEqual(valid.transactionReceipts.map(\.token), [token])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }
}
