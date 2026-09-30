import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalCapacityManagerTests: XCTestCase {
    func testOverflowGrowsPairBufferBeforeRetryingStep() async throws {
        guard let solver = MetalBubbleSolver(capacities: MetalBufferCapacities(pairs: 1, contacts: 1, corrections: 1)) else {
            throw XCTSkip("Metal unavailable")
        }
        var world = BubbleWorld(configuration: .default)
        for _ in 0..<3 {
            world.addBubble(center: .zero, restArea: .pi * 25)
        }

        let telemetry = try await solver.step(snapshot: MetalWorldSnapshot(world: world), commands: [])

        XCTAssertFalse(telemetry.didOverflow)
        XCTAssertGreaterThanOrEqual(solver.capacities.pairs, 3)
        XCTAssertTrue(telemetry.didRetry)
    }
}
