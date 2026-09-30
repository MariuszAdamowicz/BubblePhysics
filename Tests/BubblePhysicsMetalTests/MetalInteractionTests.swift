import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalInteractionTests: XCTestCase {
    func testMetalKinematicRectangleTransfersTangentialVelocity() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 58, y: 50), restArea: .pi * 25)
        var rectangle = try RigidPolygon.make(
            id: PolygonID(rawValue: 1),
            vertices: [Vector2(x: -5, y: -12), Vector2(x: 5, y: -12), Vector2(x: 5, y: 12), Vector2(x: -5, y: 12)],
            mode: .kinematic
        )
        rectangle.setKinematicTransform(position: Vector2(x: 50, y: 50), angleRadians: 0, linearVelocity: .zero, angularVelocity: 1)
        world.addRigidPolygon(rectangle)

        let result = try await solver.solveInteractions(snapshot: MetalWorldSnapshot(world: world), configuration: .default)

        XCTAssertTrue(result.particles.contains { particle in
            let velocity = particle.position - particle.previousPosition
            return abs(velocity.y) > 0.0001
        })
    }

    func testMetalGrabCapsFastTargetCorrection() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BubbleWorld(configuration: .default)
        let bubble = world.addBubble(center: .zero, restArea: .pi * 25)
        _ = world.beginGrab(bubbleID: bubble, target: Vector2(x: 100, y: 0))
        let snapshot = MetalWorldSnapshot(world: world)

        let result = try await solver.solveInteractions(snapshot: snapshot, configuration: .default)
        let movement = result.particles[0].position.x - snapshot.particles[0].position.x

        XCTAssertGreaterThan(movement, 0)
        XCTAssertLessThanOrEqual(movement, 1.5)
    }

    func testMetalSplitAndMergeConserveRestArea() throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BubbleWorld(configuration: .default)
        let first = world.addBubble(center: Vector2(x: 10, y: 10), restArea: 40)
        let second = world.addBubble(center: Vector2(x: 20, y: 10), restArea: 60)
        let snapshot = MetalWorldSnapshot(world: world)

        let merged = try solver.applyTopologyCommands([.merge(first, second)], to: snapshot)
        XCTAssertEqual(merged.bubbleRanges.map(\.restArea).reduce(0, +), 100, accuracy: 0.001)
        let split = try solver.applyTopologyCommands([.split(BubbleID(rawValue: 3))], to: merged)
        XCTAssertEqual(split.bubbleRanges.map(\.restArea).reduce(0, +), 100, accuracy: 0.001)
    }
}
