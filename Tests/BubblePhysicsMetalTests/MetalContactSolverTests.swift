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
        let range = snapshot.bubbleRanges[0]
        let centerDelta = result.particles[Int(range.centerIndex)].position - snapshot.particles[Int(range.centerIndex)].position
        let boundaryDeltas = (0..<Int(range.boundaryCount)).map { offset in
            let index = Int(range.boundaryStart) + offset
            return result.particles[index].position - snapshot.particles[index].position
        }
        XCTAssertTrue(boundaryDeltas.contains { delta in
            let difference = delta - centerDelta
            return difference.x * difference.x + difference.y * difference.y > 0.0001
        })
    }

    func testMetalReductionAppliesBothCorrectionsToSharedParticle() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }

        let correction = try await solver.reduceCorrectionsForTesting([
            MetalCorrection(particleIndex: 2, delta: SIMD2<Float>(1, 0)),
            MetalCorrection(particleIndex: 2, delta: SIMD2<Float>(0, 2))
        ])

        XCTAssertEqual(correction[2], SIMD2<Float>(1, 2))
    }

    func testMetalDenseContactsRemainFiniteAndDeterministic() async throws {
        guard let firstSolver = MetalBubbleSolver(), let secondSolver = MetalBubbleSolver() else {
            throw XCTSkip("Metal unavailable")
        }
        var world = BubbleWorld(configuration: .default)
        for row in 0..<3 {
            for column in 0..<4 {
                world.addBubble(center: Vector2(x: Float(column) * 7, y: Float(row) * 7), restArea: .pi * 25)
            }
        }
        let snapshot = MetalWorldSnapshot(world: world)

        let first = try await firstSolver.solveContacts(snapshot: snapshot, configuration: .default)
        let second = try await secondSolver.solveContacts(snapshot: snapshot, configuration: .default)

        XCTAssertEqual(first.particles, second.particles)
        XCTAssertTrue(first.particles.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
        XCTAssertTrue(first.areas.allSatisfy(\.isFinite))
    }

    func testDenseContactStepUsesBoundedCommandPassCount() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BubbleWorld(configuration: .default)
        for row in 0..<10 {
            for column in 0..<10 {
                world.addBubble(center: Vector2(x: Float(column) * 7, y: Float(row) * 7), restArea: .pi * 25)
            }
        }

        let result = try await solver.solveContacts(
            snapshot: MetalWorldSnapshot(world: world),
            configuration: .default
        )

        XCTAssertLessThanOrEqual(result.commandPassCount, WorldConfiguration.default.solverIterations * 5)
    }
}
