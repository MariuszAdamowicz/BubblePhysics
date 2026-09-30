import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalBroadPhaseTests: XCTestCase {
    func testMetalLBVHFindsOverlappingLargeAndSmallBubbles() async throws {
        guard let solver = MetalBubbleSolver() else {
            throw XCTSkip("Metal unavailable")
        }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 100, y: 100), restArea: .pi * 50 * 50)
        world.addBubble(center: Vector2(x: 145, y: 100), restArea: .pi * 5 * 5)

        let pairs = try await solver.candidatePairs(snapshot: MetalWorldSnapshot(world: world))

        XCTAssertEqual(pairs, [MetalBubblePair(firstID: 1, secondID: 2)])
    }

    func testMetalLBVHRejectsPairsSeparatedOnYEvenWhenXOverlaps() async throws {
        guard let solver = MetalBubbleSolver() else {
            throw XCTSkip("Metal unavailable")
        }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 100, y: 100), restArea: .pi * 50 * 50)
        world.addBubble(center: Vector2(x: 100, y: 170), restArea: .pi * 5 * 5)

        let pairs = try await solver.candidatePairs(snapshot: MetalWorldSnapshot(world: world))

        XCTAssertEqual(pairs, [])
    }
}
