@testable import BubblePhysics
import BubblePhysicsNativeMetal
import BubblePhysicsRuntime
import Metal
import XCTest

/// P-B-56, P-B-77: pauza w tle, odrzucenie pierwszego przyrostu czasu po powrocie, niezależność pauzy ręcznej.
@MainActor
final class LifecycleTests: XCTestCase {
    private final class FakeLifecycle: LifecycleEventSource {
        var willEnterBackground: (@MainActor () -> Void)?
        var didBecomeActive: (@MainActor () -> Void)?
        func enterBackground() { willEnterBackground?() }
        func becomeActive() { didBecomeActive?() }
    }

    private final class CountingStepper: CompleteStepper {
        private(set) var calls = 0
        func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                          commandBuffer: MTLCommandBuffer?,
                          beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
            calls += 1
            return CompletedRuntimeStep(state: batch.state)
        }
    }

    private func makeWorld(source: FakeLifecycle?, automaticPause: Bool = true,
                           stepper: CountingStepper) throws -> BubbleWorld {
        BubbleWorld(configuration: try WorldConfiguration(simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]),
            fixedTimeStep: 0.125, maximumBacklog: 10, automaticPause: automaticPause),
            stepper: stepper, lifecycle: source)
    }

    private func makeBuffer() throws -> MTLCommandBuffer {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
    }

    func testAutomaticPauseIsOnByDefault() throws {
        let configuration = try WorldConfiguration(simulationRegion: WorldRectangle(min: [-1, -1], max: [1, 1]))
        XCTAssertTrue(configuration.automaticPause)
    }

    // P-B-56: w tle `advance` zwraca ostatnią klatkę, nie woła steppera i zostawia bufor niezatwierdzony.
    func testBackgroundPausesTheWorldWithoutGPUWorkAndLeavesTheBufferUncommitted() async throws {
        let source = FakeLifecycle(), stepper = CountingStepper()
        let world = try makeWorld(source: source, stepper: stepper)
        let before = await world.advance(by: 0.125)
        XCTAssertEqual(stepper.calls, 1)
        source.enterBackground()
        XCTAssertTrue(world.diagnostics.isPaused)
        let command = try makeBuffer()
        var encoded = 0
        let frame = await world.advance(by: 1, commandBuffer: command) { encoded += 1 }
        XCTAssertEqual(frame, before)
        XCTAssertEqual(stepper.calls, 1, "krok nie jest wołany w tle")
        XCTAssertEqual(encoded, 0)
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance)
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0, "czas z pauzy nie wpada do akumulatora")
    }

    // P-B-56: po powrocie pierwszy przyrost czasu jest odrzucony, a stan ten sam; potem świat idzie dalej.
    func testFirstAdvanceAfterReturnDiscardsItsTimeAndKeepsTheState() async throws {
        let source = FakeLifecycle(), stepper = CountingStepper()
        let world = try makeWorld(source: source, stepper: stepper)
        let before = await world.advance(by: 0.125)
        source.enterBackground()
        _ = await world.advance(by: 5)
        source.becomeActive()
        XCTAssertFalse(world.diagnostics.isPaused)
        let first = await world.advance(by: 0.5)
        XCTAssertEqual(first, before, "stan ten sam")
        XCTAssertEqual(stepper.calls, 1, "przyrost 0,5 s odrzucony, więc nie ma kroku")
        XCTAssertEqual(world.diagnostics.backlogSeconds, 0)
        XCTAssertEqual(world.diagnostics.stepsInLastAdvance, 0)
        let second = await world.advance(by: 0.125)
        XCTAssertEqual(second.stepIndex, before.stepIndex + 1)
        XCTAssertEqual(stepper.calls, 2)
    }

    func testReturnWithoutPriorBackgroundDoesNotDiscardTime() async throws {
        let source = FakeLifecycle(), stepper = CountingStepper()
        let world = try makeWorld(source: source, stepper: stepper)
        source.becomeActive()
        let frame = await world.advance(by: 0.125)
        XCTAssertEqual(frame.stepIndex, 1, "didBecomeActive przy starcie aplikacji niczego nie odrzuca")
    }

    // P-B-56: opcja wyłącza zachowanie.
    func testDisabledAutomaticPauseIgnoresLifecycleEvents() async throws {
        let source = FakeLifecycle(), stepper = CountingStepper()
        let world = try makeWorld(source: source, automaticPause: false, stepper: stepper)
        source.enterBackground()
        XCTAssertFalse(world.diagnostics.isPaused)
        let command = try makeBuffer()
        var encoded = 0
        let frame = await world.advance(by: 0.125, commandBuffer: command) { encoded += 1 }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertEqual(stepper.calls, 1)
        XCTAssertEqual(encoded, 1)
        XCTAssertTrue(world.diagnostics.didRenderLastAdvance)
        source.becomeActive()
        let next = await world.advance(by: 0.125)
        XCTAssertEqual(next.stepIndex, 2, "bez automatycznej pauzy powrót nie odrzuca czasu")
    }

    // P-B-77: ręczna pauza przetrwa powrót z tła; automatyczna i ręczna nie znoszą się nawzajem.
    func testManualPauseSurvivesReturnFromBackground() async throws {
        let source = FakeLifecycle(), stepper = CountingStepper()
        let world = try makeWorld(source: source, stepper: stepper)
        world.pause()
        source.enterBackground()
        source.becomeActive()
        XCTAssertTrue(world.diagnostics.isPaused)
        _ = await world.advance(by: 1)
        XCTAssertEqual(stepper.calls, 0)
        world.resume()
        XCTAssertFalse(world.diagnostics.isPaused)
        let frame = await world.advance(by: 0.125)
        XCTAssertEqual(frame.stepIndex, 1, "po resume gry świat idzie dalej; ręczna pauza nie zostawiła czasu do odrzucenia")
        XCTAssertEqual(stepper.calls, 1)
    }

    func testManualResumeInBackgroundDoesNotLiftTheAutomaticPause() async throws {
        let source = FakeLifecycle(), stepper = CountingStepper()
        let world = try makeWorld(source: source, stepper: stepper)
        world.pause()
        source.enterBackground()
        world.resume()
        XCTAssertTrue(world.diagnostics.isPaused, "dalej w tle")
        _ = await world.advance(by: 1)
        XCTAssertEqual(stepper.calls, 0)
        source.becomeActive()
        XCTAssertFalse(world.diagnostics.isPaused)
    }

    func testBackgroundDuringManualPauseIsNotLiftedByReturn() async throws {
        let source = FakeLifecycle(), stepper = CountingStepper()
        let world = try makeWorld(source: source, stepper: stepper)
        source.enterBackground()
        world.pause()
        source.becomeActive()
        XCTAssertTrue(world.diagnostics.isPaused, "ręczna pauza trwa po powrocie")
    }

    func testSourceDoesNotKeepTheWorldAlive() throws {
        let source = FakeLifecycle()
        weak var weakWorld: BubbleWorld?
        do {
            let world = try makeWorld(source: source, stepper: CountingStepper())
            weakWorld = world
        }
        XCTAssertNil(weakWorld)
        source.enterBackground()
        source.becomeActive()
    }
}
