import XCTest
@testable import BubblePhysics

final class RadialEnvironmentContactTests: XCTestCase {
    private let bounds = AABB(minimum: .zero, maximum: Vector2(x: 100, y: 100))

    func testEveryWallPushesInwardWithPositivePenetration() {
        let cases: [(Vector2, Vector2)] = [
            (Vector2(x: 5, y: 50), Vector2(x: 1, y: 0)),
            (Vector2(x: 95, y: 50), Vector2(x: -1, y: 0)),
            (Vector2(x: 50, y: 5), Vector2(x: 0, y: 1)),
            (Vector2(x: 50, y: 95), Vector2(x: 0, y: -1))
        ]

        for (center, expectedNormal) in cases {
            let contacts = RadialEnvironmentContacts.generate(
                bubble: bubble(center: center), bounds: bounds, polygons: []
            )
            XCTAssertTrue(contacts.contains { $0.normal == expectedNormal && $0.penetration > 0 })
        }
    }

    func testStationaryTrianglePushesSensorOutOfObstacle() {
        let triangle = polygon(
            vertices: [Vector2(x: 40, y: 40), Vector2(x: 60, y: 40), Vector2(x: 50, y: 65)]
        )

        let contacts = RadialEnvironmentContacts.generate(
            bubble: bubble(center: Vector2(x: 50, y: 50)), bounds: bounds, polygons: [triangle]
        )

        XCTAssertFalse(contacts.isEmpty)
        XCTAssertTrue(contacts.allSatisfy {
            let outside = $0.point + $0.normal * ($0.penetration + 0.01)
            return !ContourContactReference.contains(outside, contour: triangle.worldVertices)
        })
        XCTAssertTrue(contacts.allSatisfy { $0.relativeVelocity.x.isFinite && $0.relativeVelocity.y.isFinite })
    }

    func testTranslatingTriangleVelocityIsSubtractedFromRelativeSurfaceVelocity() {
        let triangle = polygon(
            vertices: [Vector2(x: 40, y: 40), Vector2(x: 60, y: 40), Vector2(x: 50, y: 65)],
            linearVelocity: Vector2(x: 7, y: -3)
        )

        let contacts = RadialEnvironmentContacts.generate(
            bubble: bubble(center: Vector2(x: 50, y: 50)), bounds: bounds, polygons: [triangle]
        )

        let contact = try! XCTUnwrap(contacts.first)
        XCTAssertEqual(contact.relativeVelocity.x, -7, accuracy: 1e-5)
        XCTAssertEqual(contact.relativeVelocity.y, 3, accuracy: 1e-5)
    }

    func testRotatingTriangleAddsTangentialSurfaceVelocity() {
        let triangle = polygon(
            vertices: [Vector2(x: 40, y: 40), Vector2(x: 60, y: 40), Vector2(x: 50, y: 65)],
            position: Vector2(x: 50, y: 50),
            angularVelocity: 2
        )

        let contacts = RadialEnvironmentContacts.generate(
            bubble: bubble(center: Vector2(x: 50, y: 50)), bounds: bounds, polygons: [triangle]
        )

        let contact = try! XCTUnwrap(contacts.first)
        let offset = contact.point - triangle.position
        let expectedObstacleVelocity = Vector2(x: -2 * offset.y, y: 2 * offset.x)
        XCTAssertEqual(contact.relativeVelocity.x, -expectedObstacleVelocity.x, accuracy: 1e-5)
        XCTAssertEqual(contact.relativeVelocity.y, -expectedObstacleVelocity.y, accuracy: 1e-5)
    }

    func testCornerPinProducesContactsForBothWalls() {
        let contacts = RadialEnvironmentContacts.generate(
            bubble: bubble(center: Vector2(x: 2, y: 2)), bounds: bounds, polygons: []
        )

        XCTAssertTrue(contacts.contains { $0.normal == Vector2(x: 1, y: 0) })
        XCTAssertTrue(contacts.contains { $0.normal == Vector2(x: 0, y: 1) })
    }

    func testPolygonEdgeCrossingBetweenSensorsProducesContact() {
        var rotatedBubble = bubble(center: Vector2(x: 50, y: 50))
        rotatedBubble.body.angle = .pi / 8
        let bar = polygon(vertices: [
            Vector2(x: 35, y: 49), Vector2(x: 65, y: 49),
            Vector2(x: 65, y: 51), Vector2(x: 35, y: 51)
        ])

        let contacts = RadialEnvironmentContacts.generate(
            bubble: rotatedBubble, bounds: bounds, polygons: [bar]
        )

        XCTAssertTrue(contacts.contains { $0.barycentric > 0 && $0.barycentric < 1 })
    }

    func testPolygonContainedByBubbleProducesContact() {
        let containedTriangle = polygon(vertices: [
            Vector2(x: 48, y: 48), Vector2(x: 52, y: 48), Vector2(x: 50, y: 52)
        ])

        let contacts = RadialEnvironmentContacts.generate(
            bubble: bubble(center: Vector2(x: 50, y: 50)),
            bounds: bounds,
            polygons: [containedTriangle]
        )

        XCTAssertFalse(contacts.isEmpty)
        XCTAssertTrue(contacts.contains { $0.barycentric > 0 && $0.barycentric < 1 })
        XCTAssertTrue(contacts.allSatisfy { $0.penetration > 0 })
    }

    func testWallContactIsDistributedBarycentrically() {
        let contacts = RadialEnvironmentContacts.generate(
            bubble: bubble(center: Vector2(x: 5, y: 50)), bounds: bounds, polygons: []
        )

        XCTAssertTrue(contacts.contains {
            $0.normal == Vector2(x: 1, y: 0) && $0.barycentric > 0 && $0.barycentric < 1
        })
    }

    func testMovingPolygonRelativeVelocityUsesContactPoint() throws {
        var rotatedBubble = bubble(center: Vector2(x: 50, y: 50))
        rotatedBubble.body.angle = .pi / 8
        let bar = polygon(
            vertices: [
                Vector2(x: 35, y: 49), Vector2(x: 65, y: 49),
                Vector2(x: 65, y: 51), Vector2(x: 35, y: 51)
            ],
            position: Vector2(x: 50, y: 50),
            linearVelocity: Vector2(x: 3, y: -2),
            angularVelocity: 1.5
        )

        let contact = RadialEnvironmentContacts.generate(
            bubble: rotatedBubble, bounds: bounds, polygons: [bar]
        ).first { $0.barycentric > 0 && $0.barycentric < 1 }

        let unwrapped = try XCTUnwrap(contact)
        let arm = unwrapped.point - bar.position
        let polygonVelocity = bar.linearVelocity + Vector2(x: -1.5 * arm.y, y: 1.5 * arm.x)
        XCTAssertEqual(unwrapped.relativeVelocity.x, -polygonVelocity.x, accuracy: 1e-4)
        XCTAssertEqual(unwrapped.relativeVelocity.y, -polygonVelocity.y, accuracy: 1e-4)
    }

    private func bubble(center: Vector2) -> RadialBubbleState {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1), center: center, targetRadius: 10,
            maxSegmentLength: 10, mass: 1
        )
        state.birthProgress = 1
        for index in state.sensors.indices {
            state.sensors[index].length = 10
            state.sensors[index].targetLength = 10
        }
        return state
    }

    private func polygon(
        vertices: [Vector2],
        position: Vector2 = .zero,
        linearVelocity: Vector2 = .zero,
        angularVelocity: Float = 0
    ) -> SimulationPolygonSnapshot {
        SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 1),
            mode: .kinematic,
            worldVertices: vertices,
            position: position,
            linearVelocity: linearVelocity,
            angularVelocity: angularVelocity
        )
    }
}
