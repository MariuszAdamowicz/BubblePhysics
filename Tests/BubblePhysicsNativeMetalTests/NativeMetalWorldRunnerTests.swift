import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalWorldRunnerTests: XCTestCase {
    func testNativeMetalIsDistinctBenchmarkBackend() {
        XCTAssertEqual(ReferenceSimulationBackend.nativeMetal.rawValue, "native-metal")
        XCTAssertNotEqual(ReferenceSimulationBackend.nativeMetal, .metal)
    }

    func testUnavailableNativeRuntimeFallsBackToWholeCPUFrame() async throws {
        var world = try makeWorld()
        var cpu = world
        let expected = cpu.step()
        let runner = NativeMetalWorldRunner(executor: UnavailableRuntime())
        let actual = await runner.step(world: &world, scenarioStep: 1)
        XCTAssertEqual(world.bubbles, cpu.bubbles)
        XCTAssertEqual(world.contacts, cpu.contacts)
        XCTAssertEqual(actual.generatedContactCount, expected.generatedContactCount)
        XCTAssertEqual(actual.solver, expected.solver)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertNotNil(runner.telemetry.fallbackReason)
        XCTAssertEqual(runner.telemetry.commandBufferCount, 0)
    }

    func testRejectedNativeFrameDoesNotPublishPartialState() async throws {
        var world = try makeWorld()
        var cpu = world
        _ = cpu.step()
        let runner = NativeMetalWorldRunner(executor: RejectedRuntime())
        _ = await runner.step(world: &world, scenarioStep: 1)
        XCTAssertEqual(world.bubbles, cpu.bubbles)
        XCTAssertEqual(world.contacts, cpu.contacts)
        XCTAssertEqual(runner.telemetry.backend, .cpu)
        XCTAssertNotNil(runner.telemetry.fallbackReason)
        XCTAssertEqual(runner.telemetry.contactCount, cpu.contacts.contacts.count)
    }

    func testMissingDeviceCannotInitializeNativeRunner() {
        XCTAssertNil(NativeMetalWorldRunner(device: nil))
    }

    func testConfigurationSanitizesInvalidValues() {
        let configuration = NativeMetalConfiguration(solverIterationCount: -1, cacheExpiryFrames: -1,
            teleportDistanceMultiplier: .nan, ccdVelocityMultiplier: -.infinity).sanitized
        XCTAssertEqual(configuration.solverIterationCount, 1)
        XCTAssertEqual(configuration.cacheExpiryFrames, 0)
        XCTAssertEqual(configuration.teleportDistanceMultiplier, NativeMetalConfiguration.default.teleportDistanceMultiplier)
        XCTAssertEqual(configuration.ccdVelocityMultiplier, NativeMetalConfiguration.default.ccdVelocityMultiplier)
    }

    private func makeWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero,
            velocity: .init(x: 1, y: 0), mass: 1, targetRadius: 1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 1.5, y: 0),
            mass: 1, targetRadius: 1))
        return world
    }
}

@MainActor
private struct UnavailableRuntime: NativeMetalFrameExecuting {
    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        throw NativeMetalWorldError.unavailable
    }
}

@MainActor
private struct RejectedRuntime: NativeMetalFrameExecuting {
    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        var scratch = world
        let report = scratch.step()
        var bubbles = scratch.bubbles
        bubbles[0].center.x = .nan
        return .init(bubbles: bubbles, contacts: [], report: report,
                     telemetry: .init(backend: .nativeMetal, didEncounterNonFinite: true))
    }
}
