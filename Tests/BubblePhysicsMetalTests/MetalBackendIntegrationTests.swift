import XCTest
import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalBackendIntegrationTests: XCTestCase {
    func testUnavailableMetalFallsBackToCPUAndAppliesQueuedCommandsOnce() async {
        var world = BubbleWorld(configuration: .default)
        _ = world.addBubble(center: Vector2(x: 20, y: 20), restArea: 100)
        world.enqueue(.setGravity(Vector2(x: 0, y: 100)))
        let engine = MetalSimulationEngine(solver: nil)

        let result = await engine.step(world: &world)

        XCTAssertEqual(result.diagnostics.backend, .cpu)
        XCTAssertTrue(result.diagnostics.didFallbackToCPU)
        XCTAssertEqual(result.appliedCommandCount, 1)
        XCTAssertEqual(world.gravity, Vector2(x: 0, y: 100))
        XCTAssertGreaterThan(result.snapshot.particles[0].position.y, 20)
    }

    func testMetalStepProducesFiniteSnapshotAndMetalDiagnostics() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BenchmarkScenario.iPhoneX.makeWorld()
        let engine = MetalSimulationEngine(solver: solver)

        let result = await engine.step(world: &world)

        XCTAssertEqual(result.diagnostics.backend, .metal)
        XCTAssertFalse(result.diagnostics.didFallbackToCPU)
        XCTAssertFalse(result.hasNonFiniteState)
        XCTAssertEqual(result.snapshot.bubbleRanges.count, 300)
        XCTAssertGreaterThan(result.diagnostics.particleCount, 300)
    }
}
