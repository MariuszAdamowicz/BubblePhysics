import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalContactSolverTests: XCTestCase {
    func testMetalContactsSeparateOverlappingBubblesWithoutLosingRestArea() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 40, y: 50), restArea: .pi * 100)
        world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 100)
        let snapshot = MetalWorldSnapshot(world: world)

        let result = try await solver.solveContacts(snapshot: snapshot, configuration: .default)

        XCTAssertGreaterThan(result.centerDistance, 10)
        XCTAssertEqual(result.areas[0], .pi * 100, accuracy: 2)
        XCTAssertEqual(result.areas[1], .pi * 100, accuracy: 2)
    }

    func testMetalReductionAppliesBothCorrectionsToSharedParticle() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }

        let correction = try await solver.reduceCorrectionsForTesting([
            MetalCorrection(particleIndex: 2, delta: SIMD2<Float>(1, 0)),
            MetalCorrection(particleIndex: 2, delta: SIMD2<Float>(0, 2))
        ])

        XCTAssertEqual(correction[2], SIMD2<Float>(1, 2))
    }
}
