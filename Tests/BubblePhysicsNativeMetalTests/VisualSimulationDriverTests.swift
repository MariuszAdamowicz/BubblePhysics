import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class VisualSimulationDriverTests: XCTestCase {
    func testDefaultVisualDriverPublishesRealNativeContours() async throws {
        let runner = try XCTUnwrap(NativeMetalWorldRunner(configuration: .init(solverIterationCount: 4)))
        let driver = try VisualSimulationDriver(nativeRunner: runner)
        _ = await driver.advance(to: 0)
        let frame = await driver.advance(to: 1.0 / 60)
        XCTAssertEqual(frame.selectedBackend, .nativeMetal)
        XCTAssertEqual(frame.actualBackend, .nativeMetal)
        XCTAssertEqual(frame.snapshot.bubbles.count, 24)
        XCTAssertEqual(frame.snapshot.stepsExecuted, 1)
        XCTAssertEqual(frame.snapshot.contours, runner.contours)
        XCTAssertEqual(frame.gpuMilliseconds, runner.telemetry.gpuMilliseconds)
        XCTAssertNil(frame.fallbackReason)
    }

    func testSelectingCPUResetsAndUsesExistingReferenceRunner() async throws {
        let driver = try VisualSimulationDriver()
        driver.setBackend(.cpu)
        _ = await driver.advance(to: 0)
        let actual = await driver.advance(to: 1.0 / 60)
        var reference = try ReferenceVisualRunner(density: .twentyFour)
        _ = reference.advance(to: 0)
        let expected = reference.advance(to: 1.0 / 60)
        XCTAssertEqual(actual.actualBackend, .cpu)
        XCTAssertEqual(actual.snapshot.bubbles, expected.bubbles)
        XCTAssertEqual(actual.snapshot.contours, expected.contours)
        XCTAssertEqual(actual.snapshot.contacts, expected.contacts)
        XCTAssertEqual(actual.snapshot.simulationTime, expected.simulationTime)
        XCTAssertNil(actual.fallbackReason)
    }

    func testUnavailableGPUIsVisiblyLabeledCPUFallbackWithDrawableContours() async throws {
        let driver = try VisualSimulationDriver(nativeRunner: NativeMetalWorldRunner(executor: nil))
        _ = await driver.advance(to: 0)
        let frame = await driver.advance(to: 1.0 / 60)
        XCTAssertEqual(frame.selectedBackend, .nativeMetal)
        XCTAssertEqual(frame.actualBackend, .cpu)
        XCTAssertEqual(frame.fallbackReason, "unavailable")
        XCTAssertEqual(frame.snapshot.contours.count, 24)
    }

    func testConcurrentPresentationDoesNotStartSecondSimulationStep() async throws {
        let executor = SuspendedVisualExecutor()
        let driver = try VisualSimulationDriver(nativeRunner: NativeMetalWorldRunner(executor: executor))
        _ = await driver.advance(to: 0)
        let first = Task { await driver.advance(to: 1.0 / 60) }
        while !executor.started { await Task.yield() }
        let skipped = await driver.advance(to: 2.0 / 60)
        XCTAssertEqual(skipped.snapshot.simulationTime, 0)
        executor.resume()
        let completed = await first.value
        XCTAssertEqual(completed.snapshot.simulationTime, 1.0 / 60, accuracy: 1e-12)
        XCTAssertNotEqual(completed.fallbackReason, "frameInFlight")
    }

    func testResetWhileAwaitingGPUDiscardsOldPublication() async throws {
        let executor = SuspendedVisualExecutor()
        let driver = try VisualSimulationDriver(nativeRunner: NativeMetalWorldRunner(executor: executor))
        _ = await driver.advance(to: 0)
        let first = Task { await driver.advance(to: 1.0 / 60) }
        while !executor.started { await Task.yield() }
        driver.reset()
        executor.resume()
        let completed = await first.value
        XCTAssertEqual(completed.snapshot.simulationTime, 0)
        XCTAssertEqual(driver.frame.snapshot.simulationTime, 0)
    }

    func testExternalDragMappingRejectsNonFiniteAndZeroViewport() async throws {
        XCTAssertNil(VisualSimulationDriver.worldPoint(x: .nan, y: 1, width: 375, height: 700))
        XCTAssertNil(VisualSimulationDriver.worldPoint(x: 1, y: 1, width: 0, height: 700))
        XCTAssertEqual(VisualSimulationDriver.worldPoint(x: 300, y: 700, width: 750, height: 1400), .init(x: 150, y: 350))
        let driver = try VisualSimulationDriver()
        _ = await driver.advance(to: 0)
        driver.movePolygon(to: .init(x: .infinity, y: .nan))
        let frame = await driver.advance(to: 1.0 / 60)
        XCTAssertTrue(frame.snapshot.triangleVertices.allSatisfy(\.isFinite))
        XCTAssertEqual(frame.snapshot.triangleVertices[0], .init(x: 141.5, y: 384))
    }

    func testDragMovesGPUSceneSegmentsAndStressDensityHas300Bubbles() async throws {
        let driver = try VisualSimulationDriver()
        driver.setDensity(.threeHundred)
        _ = await driver.advance(to: 0)
        driver.movePolygon(to: .init(x: 205.5, y: 350))
        let frame = await driver.advance(to: 1.0 / 60)
        XCTAssertEqual(frame.snapshot.bubbles.count, 300)
        XCTAssertEqual(frame.actualBackend, .nativeMetal)
        XCTAssertEqual(frame.snapshot.triangleVertices[0], .init(x: 159.5, y: 384))
        XCTAssertEqual(frame.containmentCount, 0)
        XCTAssertFalse(frame.hasNonFiniteState)
    }
}

@MainActor
private final class SuspendedVisualExecutor: NativeMetalFrameExecuting {
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func resume() { continuation?.resume(); continuation = nil }
    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        started = true
        await withCheckedContinuation { continuation = $0 }
        throw NativeMetalWorldError.unavailable
    }
}
