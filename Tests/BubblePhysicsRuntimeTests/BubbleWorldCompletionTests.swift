@testable import BubblePhysics
import BubblePhysicsRuntime
import XCTest

@MainActor
final class BubbleWorldCompletionTests: XCTestCase {
    private func world(stepper: any CompleteStepper) throws -> BubbleWorld {
        BubbleWorld(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 0.125,
            maximumBacklog: 10), stepper: stepper)
    }

    // P-B-21, P-B-64: licznik przepełnienia kandydatów narasta z kroku na krok, a maksimum na obiekt dotyczy ostatniego kroku.
    func testDiagnosticsAccumulateCandidateOverflowAndReportLastStepMaximum() async throws {
        let stepper = ScriptedCandidateStepper(script: [(overflow: 3, maximum: 7), (overflow: 0, maximum: 5), (overflow: 2, maximum: 9)])
        let world = try world(stepper: stepper)
        XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 0)
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 3)
        XCTAssertEqual(world.diagnostics.maximumContactCandidatesPerObject, 7)
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 3, "krok bez przepełnienia nie zeruje licznika")
        XCTAssertEqual(world.diagnostics.maximumContactCandidatesPerObject, 5)
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 5)
        XCTAssertEqual(world.diagnostics.maximumContactCandidatesPerObject, 9)
    }

    func testFailedStepDoesNotChangeCandidateOverflowCounter() async throws {
        let world = try world(stepper: ScriptedCandidateStepper(script: [(overflow: 4, maximum: 6)], failOnSecondCall: true))
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 4)
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed)
        XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 4)
        XCTAssertEqual(world.diagnostics.maximumContactCandidatesPerObject, 6)
    }

    func testFailedStepPreservesFrameTimeStateAndQueuedTransactionForRetry() async throws {
        let stepper = FailingStepper(failureCall: 1)
        let world = try world(stepper: stepper)
        let initial = await world.advance(by: 0)
        let style = RenderStyleID(rawValue: 1)
        let object = ObjectID(rawValue: 1)
        let add = world.submit(try WorldTransaction().updateRenderStyle(style, style: RenderStyle())
            .add(.sensor(SensorDescriptor(id: object, position: .zero,
                geometry: .circle(radius: 1), renderStyleID: style))))
        let failed = await world.advance(by: 0.125)
        XCTAssertEqual(failed, initial)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.125)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed)
        let remove = world.submit(WorldTransaction().remove(object))
        let retried = await world.advance(by: 0)
        XCTAssertEqual(retried.stepIndex, 1)
        XCTAssertEqual(retried.transactionReceipts.map(\.token), [add, remove])
        XCTAssertTrue(retried.events.isEmpty)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 0)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    func testFailureAfterCompleteStepReturnsItsFrameAndKeepsOnlyUnsimulatedTime() async throws {
        let world = try world(stepper: FailingStepper(failureCall: 2))
        let token = world.submit(WorldTransaction())
        let partialAdvance = await world.advance(by: 0.375)
        XCTAssertEqual(partialAdvance.stepIndex, 1)
        XCTAssertEqual(partialAdvance.simulationTime, 0.125)
        XCTAssertEqual(partialAdvance.transactionReceipts.map(\.token), [token])
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.25)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed)
        let retried = await world.advance(by: 0)
        XCTAssertEqual(retried.stepIndex, 3)
        XCTAssertEqual(retried.simulationTime, 0.375)
        XCTAssertTrue(retried.transactionReceipts.isEmpty)
    }

    func testSuspendedStepDoesNotPublishCandidateOrConsumeNewlyQueuedTransaction() async throws {
        let stepper = SuspendedStepper()
        let world = try world(stepper: stepper)
        let first = world.submit(WorldTransaction())
        let started = expectation(description: "step started")
        stepper.didStart = { started.fulfill() }
        let advancing = Task { await world.advance(by: 0.25) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(world.diagnostics.isAdvancing)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.25)
        let reentrant = await world.advance(by: 100)
        XCTAssertEqual(reentrant.stepIndex, 0)
        XCTAssertTrue(reentrant.transactionReceipts.isEmpty)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.25)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .advanceAlreadyInProgress)
        let second = world.submit(WorldTransaction())
        world.pause()
        stepper.release()
        let completed = await advancing.value
        XCTAssertEqual(completed.stepIndex, 1)
        XCTAssertEqual(completed.transactionReceipts.map(\.token), [first])
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.125)
        XCTAssertFalse(world.diagnostics.isAdvancing)
        world.resume()
        let resumed = await world.advance(by: 0)
        XCTAssertEqual(resumed.stepIndex, 2)
        XCTAssertEqual(resumed.transactionReceipts.map(\.token), [second])
    }

    func testCancelledAdvancePreservesPendingWorkForNextCall() async throws {
        let world = try world(stepper: FailingStepper(failureCall: nil))
        let token = world.submit(WorldTransaction())
        let cancelled = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return await world.advance(by: 0.125)
        }
        let frame = await cancelled.value
        XCTAssertEqual(frame.stepIndex, 0)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .advanceCancelled)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        let retry = await world.advance(by: 0)
        XCTAssertEqual(retry.transactionReceipts.map(\.token), [token])
        XCTAssertEqual(retry.stepIndex, 1)
    }
}

/// Wyłącznie zewnętrzna granica ukończenia kroku jest kontrolowana przez test.
/// Walidacja, staging, kolejka, zegar i publikacja są produkcyjne.
@MainActor
private final class FailingStepper: CompleteStepper {
    private enum Failure: Error { case expected }
    private let failureCall: Int?
    private var call = 0
    init(failureCall: Int?) { self.failureCall = failureCall }
    func completeStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep {
        call += 1
        if call == failureCall { throw Failure.expected }
        return CompletedRuntimeStep(state: batch.state)
    }
}

@MainActor
private final class SuspendedStepper: CompleteStepper {
    var didStart: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldSuspend = true
    func completeStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep {
        if shouldSuspend {
            shouldSuspend = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                didStart?()
            }
        }
        return CompletedRuntimeStep(state: batch.state)
    }
    func release() { continuation?.resume(); continuation = nil }
}

private final class ScriptedCandidateStepper: CompleteStepper {
    private let script: [(overflow: Int, maximum: Int)]
    private let failOnSecondCall: Bool
    private var calls = 0
    init(script: [(overflow: Int, maximum: Int)], failOnSecondCall: Bool = false) {
        self.script = script; self.failOnSecondCall = failOnSecondCall
    }
    func completeStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep {
        defer { calls += 1 }
        if failOnSecondCall && calls == 1 { throw ScriptedFailure.failed }
        let entry = script[min(calls, script.count - 1)]
        return CompletedRuntimeStep(state: batch.state, contactCandidateOverflowCount: entry.overflow,
            maximumContactCandidatesPerObject: entry.maximum)
    }
}

private enum ScriptedFailure: Error { case failed }
