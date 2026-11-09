@testable import BubblePhysics
import BubblePhysicsNativeMetal
import BubblePhysicsRuntime
import Metal
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

    // P-B-72: krok odrzucony przez solver (strażnik) zachowuje klatkę, czas i kolejkę, a powód trafia do diagnostyki.
    func testRejectedSolverStepKeepsFrameTimeAndQueueForRetry() async throws {
        let stepper = ScriptedStepper([.fail(safety(.guardFailure)), .complete])
        let world = try world(stepper: stepper)
        let initial = await world.advance(by: 0)
        let style = RenderMaterialID(rawValue: 1)
        let object = ObjectID(rawValue: 1)
        let add = world.submit(try WorldTransaction().updateRenderMaterial(style, material: try RenderMaterial())
            .add(.sensor(SensorDescriptor(id: object, position: .zero,
                geometry: .circle(radius: 1)))))
        let failed = await world.advance(by: 0.125)
        XCTAssertEqual(failed, initial)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.125)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed)
        XCTAssertEqual(world.diagnostics.lastRejectionReason, .solverGuard)
        XCTAssertNil(world.diagnostics.failureReason, "strażnik nie kończy świata")
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

    // P-B-72: każdy inny błąd solvera niż wykonanie GPU i NaN/∞ odrzuca krok bez „zawiódł”, kolejka czeka.
    func testNonTerminalSolverErrorsRejectOnlyTheStepAndNameTheReason() async throws {
        let cases: [(Error, WorldRejectionReason)] = [
            (safety(.guardFailure), .solverGuard), (safety(.invalidFrame), .invalidFrame),
            (NativeMetalSolverError.invalidSnapshot, .invalidSnapshot),
            (NativeMetalWorldError.frameInFlight, .frameInFlight),
            (NativeMetalSolverError.capacityOverflow, .unexpected)]
        for (error, reason) in cases {
            let stepper = ScriptedStepper([.fail(error), .complete])
            let world = try world(stepper: stepper)
            let token = world.submit(WorldTransaction())
            let rejected = await world.advance(by: 0.125)
            XCTAssertEqual(rejected.stepIndex, 0, "\(error)")
            XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed, "\(error)")
            XCTAssertEqual(world.diagnostics.lastRejectionReason, reason, "\(error)")
            XCTAssertNil(world.diagnostics.failureReason, "\(error)")
            XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1, "\(error)")
            XCTAssertEqual(stepper.publishedCount, 0, "krok odrzucony nie jest publikowany")
            let retried = await world.advance(by: 0)
            XCTAssertEqual(retried.stepIndex, 1, "\(error)")
            XCTAssertEqual(retried.transactionReceipts.map(\.token), [token])
            XCTAssertEqual(stepper.publishedCount, 1)
        }
    }

    // P-B-57, G10-AC4: błąd wykonania bufora na GPU przełącza świat w „zawiódł”; kolejka porzucona, advance i submit nic nie robią.
    func testGPUExecutionErrorFailsTheWorldAndDropsTheQueue() async throws {
        let stepper = ScriptedStepper([.complete, .fail(NativeMetalSolverError.commandFailed("GPU")), .complete])
        let world = try world(stepper: stepper)
        let first = await world.advance(by: 0.125)
        XCTAssertEqual(first.stepIndex, 1)
        world.submit(WorldTransaction())
        let failed = await world.advance(by: 0.125)
        XCTAssertEqual(failed, first, "advance zwraca ostatnią klatkę")
        XCTAssertEqual(world.diagnostics.failureReason, .commandExecutionFailed)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .worldFailed)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 0, "kolejka porzucona")
        try await assertWorldStaysFailed(world, stepper: stepper, lastFrame: first, expectedCalls: 2)
    }

    // P-B-57: wartości nieskończone w stanie (NaN, ±∞) też kończą świat; powód jest inny niż błąd GPU.
    func testNonFiniteSafetyFailureFailsTheWorld() async throws {
        let stepper = ScriptedStepper([.fail(safety(.nonFinite)), .complete])
        let world = try world(stepper: stepper)
        world.submit(WorldTransaction())
        let frame = await world.advance(by: 0.125)
        XCTAssertEqual(frame.stepIndex, 0)
        XCTAssertEqual(world.diagnostics.failureReason, .nonFiniteValues)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 0)
        try await assertWorldStaysFailed(world, stepper: stepper, lastFrame: frame, expectedCalls: 1)
    }

    // P-B-55: stan końcowy wygrywa z pauzą i z krokiem; submit zwraca token, którego żadna klatka nie potwierdzi.
    private func assertWorldStaysFailed(_ world: BubbleWorld, stepper: ScriptedStepper, lastFrame: WorldFrame,
                                        expectedCalls: Int) async throws {
        let before = world.submit(WorldTransaction())
        let after = world.submit(WorldTransaction())
        XCTAssertNotEqual(before, after, "tokeny nadal są unikalne")
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 0, "submit nie dopisuje do kolejki")
        world.pause()
        var frame = await world.advance(by: 1)
        XCTAssertEqual(frame, lastFrame)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .worldFailed)
        world.resume()
        frame = await world.advance(by: 1)
        XCTAssertEqual(frame, lastFrame)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .worldFailed)
        XCTAssertEqual(world.diagnostics.stepsInLastAdvance, 0)
        XCTAssertEqual(stepper.calls, expectedCalls, "po „zawiódł” stepper nie jest wołany")
        XCTAssertFalse(frame.transactionReceipts.map(\.token).contains(before))
        XCTAssertNotNil(world.diagnostics.failureReason)
    }

    // P-B-58, G9-AC2: błąd domknięcia gry odrzuca tylko klatkę, a ponowienie z działającym domknięciem się udaje.
    func testThrowingGameClosureRejectsTheFrameButNotTheWorld() async throws {
        struct GameError: Error {}
        let queue = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        let stepper = ScriptedStepper([.encodeThenCommit, .encodeThenCommit])
        let world = try world(stepper: stepper)
        let token = world.submit(WorldTransaction())
        let first = await world.advance(by: 0.125, commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())) {
            throw GameError()
        }
        XCTAssertEqual(first.stepIndex, 0)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertEqual(world.diagnostics.lastRejectionReason, .frameEncoding)
        XCTAssertNil(world.diagnostics.failureReason)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0.125)
        XCTAssertEqual(stepper.publishedCount, 0, "klatka odrzucona nie wywołuje didPublish")
        var rendered = 0
        let retried = await world.advance(by: 0, commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())) { rendered += 1 }
        XCTAssertEqual(rendered, 1)
        XCTAssertEqual(retried.stepIndex, 1)
        XCTAssertEqual(retried.transactionReceipts.map(\.token), [token])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertEqual(stepper.publishedCount, 1)
    }

    // P-B-58: ten sam błąd domknięcia w gałęzi bez kroku GPU (stepper nie zakodował nic do bufora aplikacji).
    func testThrowingGameClosureWithoutGPUStepRejectsTheFrameToo() async throws {
        struct GameError: Error {}
        let queue = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        let stepper = ScriptedStepper([.complete, .complete])
        let world = try world(stepper: stepper)
        let token = world.submit(WorldTransaction())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let first = await world.advance(by: 0.125, commandBuffer: command) { throw GameError() }
        XCTAssertEqual(first.stepIndex, 0)
        XCTAssertEqual(command.status, .notEnqueued, "bufor odrzuconej klatki zostaje niezatwierdzony")
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertNil(world.diagnostics.failureReason)
        XCTAssertEqual(world.diagnostics.pendingTransactionCount, 1)
        XCTAssertEqual(stepper.publishedCount, 0)
        let retry = try XCTUnwrap(queue.makeCommandBuffer())
        let retried = await world.advance(by: 0, commandBuffer: retry) {}
        XCTAssertEqual(retried.stepIndex, 1)
        XCTAssertEqual(retried.transactionReceipts.map(\.token), [token])
        XCTAssertEqual(retry.status, .completed)
        XCTAssertEqual(stepper.publishedCount, 1)
    }

    // P-B-58: błąd zakodowania renderu, który wyszedł z `beforeCommit`, nie jest mylony z błędem solvera nawet wtedy, gdy
    // sam jest typem błędu solvera.
    func testGameClosureThrowingASolverShapedErrorStaysAFrameRejection() async throws {
        let queue = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        let world = try world(stepper: ScriptedStepper([.encodeThenCommit]))
        world.submit(WorldTransaction())
        _ = await world.advance(by: 0.125, commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())) {
            throw NativeMetalSolverError.commandFailed("domknięcie gry")
        }
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertNil(world.diagnostics.failureReason, "błąd gry nie kończy świata")
    }

    // `didPublish` tylko po publikacji kroku, raz na krok.
    func testDidPublishRunsOncePerPublishedStepOnly() async throws {
        let stepper = ScriptedStepper([.complete, .fail(safety(.invalidFrame)), .complete, .complete])
        let world = try world(stepper: stepper)
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(stepper.publishedCount, 1)
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(stepper.publishedCount, 1, "odrzucony krok")
        // Zaległość z odrzuconego kroku (0,125 s) plus 0,25 s to trzy kroki, każdy publikowany raz.
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.stepIndex, 4)
        XCTAssertEqual(stepper.publishedCount, 4)
    }

    // P-B-58: stepper zmienia historię kontaktów dopiero w `didPublish`; krok policzony i odrzucony zostawia ją bez zmian,
    // także w gałęzi bez kroku GPU, gdzie historia zmieniała się przed renderem.
    func testNativeStepperChangesContactHistoryOnlyInDidPublish() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let bubbleMaterial = PhysicsMaterialID(rawValue: 1), rigidMaterial = PhysicsMaterialID(rawValue: 2)
        let style = RenderMaterialID(rawValue: 1)
        var state = RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [0, 0], max: [600, 300]), fixedTimeStep: 1.0 / 60, globalForce: [0, -400]))
        let floor = try RigidBodyDescriptor(id: ObjectID(rawValue: 100),
            vertices: [[-300, -5], [300, -5], [300, 5], [-300, 5]], position: [300, 5], mass: 1,
            momentOfInertia: 1, motionRole: .static, physicsMaterialID: rigidMaterial, renderMaterialID: style)
        let bubble = try BubbleDescriptor(id: ObjectID(rawValue: 1), position: [150, 18.3], targetRadius: 8,
            physicsMaterialID: bubbleMaterial, renderMaterialID: style, eventInterest: .contact)
        state = try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(rigidMaterial, material: PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial()).add(.rigidBody(floor)).add(.bubble(bubble)),
            against: state).state
        for _ in 0..<45 {
            state = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state),
                duration: 1.0 / 60).state
        }
        let pair = ContactPair(ObjectID(rawValue: 1), ObjectID(rawValue: 100))
        XCTAssertEqual(stepper.publishedContactPairs, [pair], "styk bańki z podłogą ma historię po publikacji")
        // Krok bez GPU: oba ciała usunięte, więc para znika z historii dopiero po didPublish.
        let removal = TransactionStager.stageBatch([.init(token: .init(rawValue: 1), transaction:
            WorldTransaction().remove(ObjectID(rawValue: 1)).remove(ObjectID(rawValue: 100)))], against: state)
        let candidate = try await stepper.completeStep(removal, duration: 1.0 / 60, hitTests: [],
            commandBuffer: nil, beforeCommit: nil)
        XCTAssertEqual(stepper.publishedContactPairs, [pair], "krok policzony, ale nieopublikowany, nie zmienia historii")
        let again = try await stepper.completeStep(removal, duration: 1.0 / 60, hitTests: [],
            commandBuffer: nil, beforeCommit: nil)
        XCTAssertEqual(again.events, candidate.events, "ponowienie odrzuconego kroku daje te same zdarzenia")
        XCTAssertEqual(stepper.publishedContactPairs, [pair])
        stepper.didPublish(again)
        XCTAssertTrue(stepper.publishedContactPairs.isEmpty)
        stepper.didPublish(again)
        XCTAssertTrue(stepper.publishedContactPairs.isEmpty, "didPublish bez nowego kroku nic nie zmienia")
    }

    // MARK: hit-test (P-B-31, P-B-33)

    private func waitForPending(_ world: BubbleWorld, _ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 where world.pendingHitTestCount != count { await Task.yield() }
        XCTAssertEqual(world.pendingHitTestCount, count, file: file, line: line)
    }

    // Punkty oczekujących zapytań trafiają do metody kroku w kolejności zgłoszenia, a wyniki wracają do właściwych zapytań.
    func testHitTestsReachTheStepInOrderAndResumeWithTheirOwnResults() async throws {
        let stepper = HitTestStepper(results: [ObjectID(rawValue: 5), nil, ObjectID(rawValue: 7)])
        let world = try world(stepper: stepper)
        let first = Task { @MainActor in await world.hitTest([1, 1]) }
        await waitForPending(world, 1)
        let second = Task { @MainActor in await world.hitTest([2, 2]) }
        await waitForPending(world, 2)
        let third = Task { @MainActor in await world.hitTest([3, 3]) }
        await waitForPending(world, 3)
        _ = await world.advance(by: 0.125)
        let results = [await first.value, await second.value, await third.value]
        XCTAssertEqual(stepper.receivedHitTests, [[[1, 1], [2, 2], [3, 3]]])
        XCTAssertEqual(results, [ObjectID(rawValue: 5), nil, ObjectID(rawValue: 7)])
        XCTAssertEqual(world.pendingHitTestCount, 0)
    }

    // Stepper bez wyników (stary kontrakt) oznacza puste miejsce dla każdego punktu; zapytanie się kończy.
    func testMissingStepResultsMeanNilForEveryPoint() async throws {
        let world = try world(stepper: HitTestStepper(results: []))
        let task = Task { @MainActor in await world.hitTest([1, 1]) }
        await waitForPending(world, 1)
        _ = await world.advance(by: 0.125)
        let result = await task.value
        XCTAssertNil(result)
        XCTAssertEqual(world.pendingHitTestCount, 0)
    }

    // Krok odrzucony przez solver i klatka odrzucona przez grę zostawiają zapytania w kolejce; ponowny krok dostaje te same punkty.
    func testRejectedStepAndRejectedFrameKeepHitTestsWaiting() async throws {
        let queue = try XCTUnwrap(MTLCreateSystemDefaultDevice()?.makeCommandQueue())
        let stepper = HitTestStepper(results: [ObjectID(rawValue: 5)],
            script: [.fail(safety(.guardFailure)), .encodeThenCommit, .encodeThenCommit])
        let world = try world(stepper: stepper)
        let task = Task { @MainActor in await world.hitTest([4, 4]) }
        await waitForPending(world, 1)
        _ = await world.advance(by: 0.125)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed)
        XCTAssertEqual(world.pendingHitTestCount, 1, "krok odrzucony")
        struct GameError: Error {}
        _ = await world.advance(by: 0, commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())) { throw GameError() }
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertEqual(world.pendingHitTestCount, 1, "klatka odrzucona")
        _ = await world.advance(by: 0, commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())) {}
        let result = await task.value
        XCTAssertEqual(result, ObjectID(rawValue: 5))
        XCTAssertEqual(stepper.receivedHitTests, [[[4, 4]], [[4, 4]], [[4, 4]]])
    }

    // P-B-33: w pauzie zapytanie czeka; po wznowieniu dostaje wynik pierwszego kroku.
    func testHitTestWaitsInPauseAndResumesWithTheFirstStepAfterResume() async throws {
        let stepper = HitTestStepper(results: [ObjectID(rawValue: 5)])
        let world = try world(stepper: stepper)
        world.pause()
        var finished = false
        let task = Task { @MainActor () -> ObjectID? in
            let result = await world.hitTest([1, 1])
            finished = true
            return result
        }
        await waitForPending(world, 1)
        _ = await world.advance(by: 1)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(finished)
        XCTAssertTrue(stepper.receivedHitTests.isEmpty)
        world.resume()
        _ = await world.advance(by: 0.125)
        let result = await task.value
        XCTAssertEqual(result, ObjectID(rawValue: 5))
    }

    // P-B-55, P-B-33: stan „zawiódł” porzuca oczekujące zapytania (nil), a kolejne wracają od razu.
    func testFailedStateAnswersPendingAndLaterHitTestsWithNilImmediately() async throws {
        let stepper = HitTestStepper(results: [ObjectID(rawValue: 5)],
            script: [.fail(NativeMetalSolverError.commandFailed("GPU"))])
        let world = try world(stepper: stepper)
        let pending = Task { @MainActor in await world.hitTest([1, 1]) }
        await waitForPending(world, 1)
        _ = await world.advance(by: 0.125)
        XCTAssertNotNil(world.diagnostics.failureReason)
        let pendingResult = await pending.value
        XCTAssertNil(pendingResult)
        XCTAssertEqual(world.pendingHitTestCount, 0)
        let later = await world.hitTest([2, 2])
        XCTAssertNil(later)
        XCTAssertEqual(world.pendingHitTestCount, 0)
        XCTAssertEqual(stepper.receivedHitTests.count, 1, "po „zawiódł” stepper nie jest wołany")
    }

    // P-B-33: zapytanie złożone w czasie kroku nie dostaje wyniku tego kroku, bo jego punkt nie trafił do solvera.
    func testHitTestAddedWhileAStepIsInFlightWaitsForTheNextStep() async throws {
        let stepper = HitTestStepper(results: [ObjectID(rawValue: 5)], suspendFirstStep: true)
        let world = try world(stepper: stepper)
        let first = Task { @MainActor in await world.hitTest([1, 1]) }
        await waitForPending(world, 1)
        let started = expectation(description: "step started")
        stepper.didStart = { started.fulfill() }
        let advancing = Task { @MainActor in await world.advance(by: 0.125) }
        await fulfillment(of: [started], timeout: 2)
        let late = Task { @MainActor in await world.hitTest([9, 9]) }
        await waitForPending(world, 2)
        stepper.release()
        _ = await advancing.value
        let firstResult = await first.value
        XCTAssertEqual(firstResult, ObjectID(rawValue: 5))
        XCTAssertEqual(world.pendingHitTestCount, 1, "późne zapytanie czeka")
        _ = await world.advance(by: 0.125)
        let lateResult = await late.value
        XCTAssertEqual(lateResult, ObjectID(rawValue: 5))
        XCTAssertEqual(stepper.receivedHitTests, [[[1, 1]], [[9, 9]]])
    }

    // P-B-33: anulowane zapytanie nie trafia do kroku, a pozostałe tak.
    func testCancelledHitTestIsRemovedBeforeTheStep() async throws {
        let stepper = HitTestStepper(results: [ObjectID(rawValue: 5)])
        let world = try world(stepper: stepper)
        let cancelled = Task { @MainActor in await world.hitTest([1, 1]) }
        let kept = Task { @MainActor in await world.hitTest([2, 2]) }
        await waitForPending(world, 2)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(world.pendingHitTestCount, 1)
        _ = await world.advance(by: 0.125)
        let keptResult = await kept.value
        XCTAssertEqual(keptResult, ObjectID(rawValue: 5))
        XCTAssertEqual(stepper.receivedHitTests, [[[2, 2]]])
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

private func safety(_ reason: NativeMetalWorldError) -> NativeMetalSafetyFailure {
    NativeMetalSafetyFailure(reason: reason, telemetry: NativeMetalFrameTelemetry(), profile: NativeMetalFrameProfile())
}

/// Wyłącznie zewnętrzna granica ukończenia kroku jest kontrolowana przez test.
/// Walidacja, staging, kolejka, zegar i publikacja są produkcyjne.
@MainActor
private final class FailingStepper: CompleteStepper {
    private enum Failure: Error { case expected }
    private let failureCall: Int?
    private var call = 0
    init(failureCall: Int?) { self.failureCall = failureCall }
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        call += 1
        if call == failureCall { throw Failure.expected }
        return CompletedRuntimeStep(state: batch.state)
    }
}

/// Zachowanie kolejnych wywołań kroku jest scenariuszem testu; ostatni wpis powtarza się bez końca.
/// `.encodeThenCommit` naśladuje krok GPU: woła `beforeCommit`, a potem zatwierdza bufor aplikacji.
@MainActor
private final class ScriptedStepper: CompleteStepper {
    enum Behavior { case complete, fail(Error), encodeThenCommit }
    private let script: [Behavior]
    private(set) var calls = 0
    private(set) var published: [CompletedRuntimeStep] = []
    var publishedCount: Int { published.count }
    init(_ script: [Behavior]) { self.script = script }
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        defer { calls += 1 }
        switch script[min(calls, script.count - 1)] {
        case .complete: break
        case .fail(let error): throw error
        case .encodeThenCommit:
            try beforeCommit?(nil, batch.state)
            if let commandBuffer {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    commandBuffer.addCompletedHandler { _ in continuation.resume() }
                    commandBuffer.commit()
                }
            }
        }
        return CompletedRuntimeStep(state: batch.state)
    }
    func didPublish(_ step: CompletedRuntimeStep) { published.append(step) }
}

@MainActor
private final class SuspendedStepper: CompleteStepper {
    var didStart: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private var shouldSuspend = true
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
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
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        defer { calls += 1 }
        if failOnSecondCall && calls == 1 { throw ScriptedFailure.failed }
        let entry = script[min(calls, script.count - 1)]
        return CompletedRuntimeStep(state: batch.state, contactCandidateOverflowCount: entry.overflow,
            maximumContactCandidatesPerObject: entry.maximum)
    }
}

private enum ScriptedFailure: Error { case failed }

/// Scenariusz kroku z zapisem punktów hit-testu; wyniki to odpowiedź na każdy krok (skrócona lub dopełniona nil do liczby punktów
/// tylko wtedy, gdy podano wyniki).
@MainActor
private final class HitTestStepper: CompleteStepper {
    enum Behavior { case complete, fail(Error), encodeThenCommit }
    private let results: [ObjectID?]
    private let script: [Behavior]
    private var suspendFirstStep: Bool
    var didStart: (() -> Void)?
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var receivedHitTests: [[WorldPoint]] = []
    init(results: [ObjectID?], script: [Behavior] = [.complete], suspendFirstStep: Bool = false) {
        self.results = results; self.script = script; self.suspendFirstStep = suspendFirstStep
    }
    func release() { continuation?.resume(); continuation = nil }
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        let call = receivedHitTests.count
        receivedHitTests.append(hitTests)
        if suspendFirstStep {
            suspendFirstStep = false
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                didStart?()
            }
        }
        switch script[min(call, script.count - 1)] {
        case .complete: break
        case .fail(let error): throw error
        case .encodeThenCommit:
            try beforeCommit?(nil, batch.state)
            if let commandBuffer {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    commandBuffer.addCompletedHandler { _ in continuation.resume() }
                    commandBuffer.commit()
                }
            }
        }
        let answers = results.isEmpty ? [] : hitTests.indices.map { results[min($0, results.count - 1)] }
        return CompletedRuntimeStep(state: batch.state, hitTestResults: answers)
    }
}
