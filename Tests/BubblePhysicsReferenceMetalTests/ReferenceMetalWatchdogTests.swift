import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

@MainActor
final class ReferenceMetalWatchdogTests: XCTestCase {
    // Removing the fatal latch must cause a second submission and fail this test.
    func testFatalGPUFailureRerunsWholeFrameAndRejectsLaterSubmissions() async throws {
        let errors = [
            NSError(domain: MTLCommandBufferErrorDomain, code: 2),
            NSError(domain: MTLCommandBufferErrorDomain, code: 4),
            NSError(domain: MTLCommandBufferErrorDomain, code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "kIOGPUCommandBufferCallbackErrorHang"]),
            NSError(domain: MTLCommandBufferErrorDomain, code: 1,
                    userInfo: [NSLocalizedFailureReasonErrorKey: "SubmissionsIgnored"])
        ]
        for error in errors {
            let executor = FailingWatchdogExecutor(error: error)
            let runner = ReferenceMetalWorldRunner(executor: executor)
            var world = try makeWorld()
            var oracle = world
            for step in 7...9 {
                let expected = oracle.step()
                let actual = await runner.step(world: &world, scenarioStep: step)
                XCTAssertEqual(world.bubbles, oracle.bubbles)
                XCTAssertEqual(world.contacts.contacts, oracle.contacts.contacts)
                XCTAssertEqual(actual.solver, expected.solver)
                XCTAssertEqual(runner.telemetry.backend, .cpu)
                XCTAssertNotNil(runner.telemetry.fallbackReason)
                let failure = try XCTUnwrap(runner.telemetry.gpuFailure)
                XCTAssertEqual(failure.scenarioStep, 7)
                XCTAssertEqual(failure.stage, "executeFrame")
                XCTAssertEqual(failure.commandBufferErrorCode, error.code)
                XCTAssertEqual(failure.errorDomain, MTLCommandBufferErrorDomain)
                XCTAssertTrue(failure.isFatal)
                XCTAssertEqual(runner.firstGPUFailure, failure)
                XCTAssertEqual(runner.fatalGPUFailure, failure)
                XCTAssertTrue(runner.contours.isEmpty)
                XCTAssertTrue(runner.renderData.isEmpty)
            }
            XCTAssertEqual(executor.steps, [7], "Fatal GPU error must disable later submissions: \(error)")
        }
    }

    // Treating all execution errors (or numeric codes from other domains) as
    // fatal would incorrectly suppress a later valid GPU attempt.
    func testOrdinaryFailuresKeepPerFrameCPUFallbackWithoutLatching() async throws {
        for error in [NSError(domain: MTLCommandBufferErrorDomain, code: 9),
                      NSError(domain: "ordinary-validation", code: 2)] {
            let executor = FailingWatchdogExecutor(error: ReferenceMetalGPUFailure(
                stage: "referenceWorldFrame", scenarioStep: 1, error: error, commandBufferStatus: 5))
            let runner = ReferenceMetalWorldRunner(executor: executor)
            var world = try makeWorld()
            var oracle = world
            for step in 1...2 {
                _ = oracle.step()
                _ = await runner.step(world: &world, scenarioStep: step)
                XCTAssertEqual(world.bubbles, oracle.bubbles)
                XCTAssertEqual(runner.telemetry.backend, .cpu)
                XCTAssertEqual(runner.telemetry.gpuFailure?.classification, .ordinary)
            }
            XCTAssertEqual(executor.steps, [1, 2])
            XCTAssertNil(runner.fatalGPUFailure)
        }
    }

    // Dropping encoder info at the NSError boundary hides the failing stage.
    func testEncoderDiagnosticsSelectFaultedStageAndSurviveLatchedCPUFrames() async throws {
        let error = NSError(domain: MTLCommandBufferErrorDomain, code: 1, userInfo: [
            NSLocalizedDescriptionKey: "kIOGPUCommandBufferCallbackErrorHang",
            "driver": "iPhone X",
            MTLCommandBufferEncoderInfoErrorKey: [
                WatchdogEncoderInfo(label: "referencePredict", status: .completed),
                WatchdogEncoderInfo(label: "referenceAdvanceWorld", status: .faulted),
                WatchdogEncoderInfo(label: "referencePrepareRenderData", status: .pending)
            ]
        ])
        let failure = ReferenceMetalGPUFailure(stage: "referenceWorldFrame", scenarioStep: 12,
            error: error, commandBufferStatus: 5)
        let executor = FailingWatchdogExecutor(error: failure)
        let runner = ReferenceMetalWorldRunner(executor: executor)
        var world = try makeWorld()
        for step in 12...13 {
            _ = await runner.step(world: &world, scenarioStep: step)
            let recorded = try XCTUnwrap(runner.telemetry.gpuFailure)
            XCTAssertEqual(recorded.stage, "referenceAdvanceWorld")
            XCTAssertEqual(recorded.scenarioStep, 12)
            XCTAssertEqual(recorded.commandBufferStatus, 5)
            XCTAssertEqual(recorded.commandBufferErrorCode, 1)
            XCTAssertEqual(recorded.classification, .hang)
            XCTAssertEqual(recorded.reason, "kIOGPUCommandBufferCallbackErrorHang")
            XCTAssertEqual(recorded.errorUserInfo["driver"], "iPhone X")
            XCTAssertEqual(recorded.encoderFailures.map(\.executionStatus), [1, 4, 3])
            XCTAssertEqual(recorded.encoderFailures.first?.debugSignposts, ["dispatch"])
        }
        XCTAssertEqual(executor.steps, [12])
    }

    private func makeWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(linearDamping: 0), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 3), center: .init(x: 2, y: 1),
                                 velocity: .init(x: 4, y: -2), mass: 1, targetRadius: 0.2))
        return world
    }
}

@MainActor
private final class FailingWatchdogExecutor: ReferenceMetalFrameExecuting {
    let error: Error
    var steps: [Int] = []
    init(error: Error) { self.error = error }

    func executeFrame(snapshot: ReferenceMetalSnapshot, scenarioStep: Int) async throws -> ReferenceMetalWorldFrame {
        steps.append(scenarioStep)
        throw error
    }
}

private final class WatchdogEncoderInfo: NSObject, MTLCommandBufferEncoderInfo {
    let label: String
    let errorState: MTLCommandEncoderErrorState
    let debugSignposts = ["dispatch"]
    init(label: String, status: MTLCommandEncoderErrorState) {
        self.label = label
        errorState = status
    }
}
