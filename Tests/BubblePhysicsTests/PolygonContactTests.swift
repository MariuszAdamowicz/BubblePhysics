import XCTest
@testable import BubblePhysics

final class PolygonContactTests: XCTestCase {
    func testStaticRectanglePushesBubbleBoundaryOutOfItsContour() throws {
        var world = BubbleWorld(configuration: .default)
        let polygon = try rectangle(id: 1, mode: .static)
        world.addRigidPolygon(polygon)
        let bubble = world.addBubble(center: .zero, restArea: .pi * 16)

        for _ in 0..<30 { world.step() }

        XCTAssertFalse(world.bubble(bubble)!.boundaryPoints.contains { PolygonContactGenerator.contains($0, in: polygon) })
    }

    func testConcavePolygonUsesOnlyOuterContourForContacts() throws {
        let polygon = try RigidPolygon.make(
            id: PolygonID(rawValue: 2),
            vertices: [
                Vector2(x: -10, y: -10), Vector2(x: 10, y: -10), Vector2(x: 10, y: 10),
                Vector2(x: 0, y: 0), Vector2(x: -10, y: 10)
            ]
        )
        let bubble = BubbleTopology.regular(id: BubbleID(rawValue: 1), center: Vector2(x: 0, y: -8), restArea: .pi * 4, maxBoundarySegmentLength: 4)

        XCTAssertEqual(polygon.worldBoundaryEdges.count, 5)
        XCTAssertFalse(PolygonContactGenerator.contacts(bubble: bubble, polygon: polygon).isEmpty)
    }

    func testKinematicRectangleTransfersLinearVelocityToBubble() throws {
        var world = BubbleWorld(configuration: .default)
        var polygon = try rectangle(id: 3, mode: .kinematic)
        polygon.setKinematicTransform(position: Vector2(x: -7, y: 0), angleRadians: 0, linearVelocity: Vector2(x: 60, y: 0), angularVelocity: 0)
        world.addRigidPolygon(polygon)
        let bubble = world.addBubble(center: Vector2(x: 4, y: 0), restArea: .pi * 9)

        for offset in 0..<10 {
            world.enqueue(.setKinematicTransform(
                PolygonID(rawValue: 3),
                position: Vector2(x: -7 + Float(offset), y: 0),
                angleRadians: 0,
                linearVelocity: Vector2(x: 60, y: 0),
                angularVelocity: 0
            ))
            world.step()
        }

        XCTAssertGreaterThan(world.bubble(bubble)!.center.x, 0)
    }

    func testRotatingKinematicPolygonTransfersTangentialVelocity() throws {
        var world = BubbleWorld(configuration: .default)
        var polygon = try rectangle(id: 4, mode: .kinematic)
        polygon.setKinematicTransform(position: .zero, angleRadians: 0, linearVelocity: .zero, angularVelocity: 10)
        world.addRigidPolygon(polygon)
        let bubble = world.addBubble(center: Vector2(x: 0, y: 2), restArea: .pi * 4)

        world.step()
        world.step()

        XCTAssertLessThan(world.bubble(bubble)!.center.x, -0.1)
    }

    private func rectangle(id: Int, mode: RigidPolygonMode) throws -> RigidPolygon {
        try RigidPolygon.make(
            id: PolygonID(rawValue: id),
            vertices: [Vector2(x: -5, y: -3), Vector2(x: 5, y: -3), Vector2(x: 5, y: 3), Vector2(x: -5, y: 3)],
            mode: mode
        )
    }
}
