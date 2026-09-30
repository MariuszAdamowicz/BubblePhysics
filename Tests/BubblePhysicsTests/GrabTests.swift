import XCTest
@testable import BubblePhysics

final class GrabTests: XCTestCase {
    func testFreeGrabMovesBubbleTowardTarget() {
        var world = BubbleWorld(configuration: .default)
        let bubble = world.addBubble(center: .zero, restArea: .pi * 16)
        let grab = world.beginGrab(bubbleID: bubble, target: Vector2(x: 20, y: 0))!

        for _ in 0..<20 { world.step() }

        XCTAssertGreaterThan(world.bubble(bubble)!.center.x, 10)
        XCTAssertLessThan(world.grabState(grab)!.resistance, 10)
    }

    func testGrabUsesCappedCorrectionForFastTarget() {
        var world = BubbleWorld(configuration: .default)
        let bubble = world.addBubble(center: .zero, restArea: .pi * 16)
        let grab = world.beginGrab(bubbleID: bubble, target: Vector2(x: 1_000, y: 0))!

        world.step()

        XCTAssertLessThan(world.bubble(bubble)!.center.x, 10)
        XCTAssertGreaterThan(world.grabState(grab)!.resistance, 900)
    }
}
