import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalShapeSolverTests: XCTestCase {
    func testMetalPredictionMovesBubbleDownUnderGravity() async throws {
        guard let solver = MetalBubbleSolver() else {
            throw XCTSkip("Metal unavailable")
        }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 25)
        let snapshot = MetalWorldSnapshot(world: world)

        let result = try await solver.solveShape(
            snapshot: snapshot,
            gravity: Vector2(x: 0, y: -9.81),
            bounds: nil,
            configuration: .default
        )

        XCTAssertLessThan(result.particles[0].position.y, snapshot.particles[0].position.y)
    }

    func testMetalShapeSolverKeepsRestAreaWithinExistingTolerance() async throws {
        guard let solver = MetalBubbleSolver() else {
            throw XCTSkip("Metal unavailable")
        }
        var world = BubbleWorld(configuration: .default)
        let bubbleID = world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 100)
        let snapshot = MetalWorldSnapshot(world: world)

        let result = try await solver.solveShape(
            snapshot: snapshot,
            gravity: Vector2(x: 0, y: -9.81),
            bounds: nil,
            configuration: .default
        )
        let area = polygonArea(of: result, range: snapshot.bubbleRanges[0])

        XCTAssertEqual(bubbleID.rawValue, 1)
        XCTAssertEqual(area, .pi * 100, accuracy: 1.0)
    }

    func testMetalWorldBoundsKeepEveryBoundaryParticleInsideBounds() async throws {
        guard let solver = MetalBubbleSolver() else {
            throw XCTSkip("Metal unavailable")
        }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 100, y: 100), restArea: .pi * 100)
        let snapshot = MetalWorldSnapshot(world: world)
        let bounds = AABB(minimum: .zero, maximum: Vector2(x: 30, y: 30))

        let result = try await solver.solveShape(
            snapshot: snapshot,
            gravity: .zero,
            bounds: bounds,
            configuration: .default
        )

        for particle in result.particles {
            XCTAssertGreaterThanOrEqual(particle.position.x, 0)
            XCTAssertLessThanOrEqual(particle.position.x, 30)
            XCTAssertGreaterThanOrEqual(particle.position.y, 0)
            XCTAssertLessThanOrEqual(particle.position.y, 30)
        }
    }

    private func polygonArea(of result: MetalShapeStepResult, range: MetalBubbleRange) -> Float {
        let indices = 0..<Int(range.boundaryCount)
        var doubleArea: Float = 0
        for offset in indices {
            let current = result.particles[Int(range.boundaryStart) + offset].position
            let next = result.particles[Int(range.boundaryStart) + ((offset + 1) % indices.count)].position
            doubleArea += current.x * next.y - current.y * next.x
        }
        return abs(doubleArea) * 0.5
    }
}
