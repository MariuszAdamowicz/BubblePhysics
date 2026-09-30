import XCTest
@testable import BubblePhysics

final class RigidPolygonTests: XCTestCase {
    func testRectangleTriangulatesAndExposesOnlyOuterBoundaryEdges() throws {
        let polygon = try RigidPolygon.make(
            id: PolygonID(rawValue: 1),
            vertices: [
                Vector2(x: 0, y: 0), Vector2(x: 4, y: 0),
                Vector2(x: 4, y: 2), Vector2(x: 0, y: 2)
            ]
        )

        XCTAssertEqual(polygon.triangles.count, 2)
        XCTAssertEqual(polygon.boundaryEdges.count, 4)
        XCTAssertFalse(polygon.boundaryEdges.contains { edge in
            (edge.start == Vector2(x: 0, y: 0) && edge.end == Vector2(x: 4, y: 2)) ||
            (edge.start == Vector2(x: 4, y: 2) && edge.end == Vector2(x: 0, y: 0))
        })
    }

    func testConcavePolygonTriangulatesToVertexCountMinusTwoTriangles() throws {
        let polygon = try RigidPolygon.make(
            id: PolygonID(rawValue: 2),
            vertices: [
                Vector2(x: 0, y: 0), Vector2(x: 4, y: 0), Vector2(x: 4, y: 4),
                Vector2(x: 2, y: 2), Vector2(x: 0, y: 4)
            ]
        )

        XCTAssertEqual(polygon.triangles.count, 3)
        XCTAssertEqual(polygon.boundaryEdges.count, 5)
    }

    func testSelfIntersectingPolygonIsRejected() {
        XCTAssertThrowsError(try RigidPolygon.make(
            id: PolygonID(rawValue: 3),
            vertices: [
                Vector2(x: 0, y: 0), Vector2(x: 4, y: 4),
                Vector2(x: 0, y: 4), Vector2(x: 4, y: 0)
            ]
        ))
    }

    func testRepeatedVertexIsRejected() {
        XCTAssertThrowsError(try RigidPolygon.make(
            id: PolygonID(rawValue: 4),
            vertices: [
                Vector2(x: 0, y: 0), Vector2(x: 4, y: 0),
                Vector2(x: 4, y: 0), Vector2(x: 0, y: 4)
            ]
        ))
    }

    func testClockwiseInputIsNormalizedToCounterClockwiseOrientation() throws {
        let polygon = try RigidPolygon.make(
            id: PolygonID(rawValue: 5),
            vertices: [
                Vector2(x: 0, y: 0), Vector2(x: 0, y: 2),
                Vector2(x: 4, y: 2), Vector2(x: 4, y: 0)
            ]
        )

        XCTAssertGreaterThan(polygon.signedArea, 0)
    }

    func testKinematicTransformRotatesEdgesAndReportsSurfaceVelocity() throws {
        var polygon = try RigidPolygon.make(
            id: PolygonID(rawValue: 6),
            vertices: [
                Vector2(x: -1, y: -1), Vector2(x: 1, y: -1),
                Vector2(x: 1, y: 1), Vector2(x: -1, y: 1)
            ],
            mode: .kinematic
        )
        polygon.setKinematicTransform(
            position: Vector2(x: 10, y: 5),
            angleRadians: .pi / 2,
            linearVelocity: Vector2(x: 2, y: 0),
            angularVelocity: 3
        )

        XCTAssertEqual(polygon.worldVertices[0].x, 11, accuracy: 0.0001)
        XCTAssertEqual(polygon.worldVertices[0].y, 4, accuracy: 0.0001)
        XCTAssertEqual(polygon.surfaceVelocity(at: Vector2(x: 10, y: 6)), Vector2(x: -1, y: 0))
    }
}
