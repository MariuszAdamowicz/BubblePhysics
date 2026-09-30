import XCTest
@testable import BubblePhysics

final class XPBDTests: XCTestCase {
    func testGravityMovesBubbleDownwardWithinFixedStepWorld() {
        var world = BubbleWorld(configuration: .default)
        let id = world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 25)
        world.enqueue(.setGravity(Vector2(x: 0, y: -9.81)))

        world.step()
        world.step()

        XCTAssertLessThan(world.bubble(id)!.center.y, 50)
    }

    func testBoundaryConstraintsKeepAllBoundaryPointsInsideWorld() {
        var world = BubbleWorld(configuration: .default, bounds: AABB(minimum: .zero, maximum: Vector2(x: 100, y: 100)))
        let id = world.addBubble(center: Vector2(x: 2, y: 2), restArea: .pi * 100)

        world.step()

        XCTAssertTrue(world.bubble(id)!.boundaryPoints.allSatisfy { $0.x >= 0 && $0.y >= 0 })
    }

    func testRestAreaStaysStableOverManySolverSteps() {
        var world = BubbleWorld(configuration: .default)
        let id = world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 100)
        world.enqueue(.applyForce(id, Vector2(x: 100, y: 0)))

        for _ in 0..<120 { world.step() }

        XCTAssertEqual(world.currentArea(of: id)!, .pi * 100, accuracy: 2)
        XCTAssertFalse(world.bubble(id)!.boundaryPoints.contains { !$0.x.isFinite || !$0.y.isFinite })
    }

    func testInternalDistanceConstraintsKeepRegularBubbleShapeDuringMotion() {
        var world = BubbleWorld(configuration: .default)
        let id = world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 100)
        let initial = world.bubble(id)!
        let initialRadius = distance(initial.boundaryPoints[0], initial.center)
        world.enqueue(.applyForce(id, Vector2(x: 500, y: -100)))

        for _ in 0..<120 { world.step() }

        let final = world.bubble(id)!
        XCTAssertEqual(distance(final.boundaryPoints[0], final.center), initialRadius, accuracy: 0.05)
        XCTAssertEqual(distance(final.boundaryPoints[0], final.boundaryPoints[1]), distance(initial.boundaryPoints[0], initial.boundaryPoints[1]), accuracy: 0.05)
    }

    func testLinearDampingReducesTravelAfterSameImpulse() {
        let undamped = WorldConfiguration(fixedTimeStep: 1.0 / 60.0, solverIterations: 8, maxBoundarySegmentLength: 8, linearDamping: 0)
        let damped = WorldConfiguration(fixedTimeStep: 1.0 / 60.0, solverIterations: 8, maxBoundarySegmentLength: 8, linearDamping: 0.5)
        var fastWorld = BubbleWorld(configuration: undamped)
        var calmWorld = BubbleWorld(configuration: damped)
        let fast = fastWorld.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 25)
        let calm = calmWorld.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 25)
        fastWorld.enqueue(.applyForce(fast, Vector2(x: 1_000, y: 0)))
        calmWorld.enqueue(.applyForce(calm, Vector2(x: 1_000, y: 0)))

        for _ in 0..<30 {
            fastWorld.step()
            calmWorld.step()
        }

        XCTAssertGreaterThan(fastWorld.bubble(fast)!.center.x, calmWorld.bubble(calm)!.center.x)
    }

    private func distance(_ first: Vector2, _ second: Vector2) -> Float {
        let delta = first - second
        return (delta.dot(delta)).squareRoot()
    }
}
