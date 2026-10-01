import XCTest
@testable import BubblePhysics

final class ContourContactTests: XCTestCase {
    func testContainedPointUsesNearestEdgeAndBarycentricCoordinate() throws {
        let first = [Vector2(x: 1, y: 1), Vector2(x: 1.5, y: 1), Vector2(x: 1, y: 1.5)]
        let second = square(min: .zero, max: Vector2(x: 4, y: 4))

        let contacts = ContourContactReference.contacts(first: first, second: second)
        let contact = contacts.first { $0.pointIndex == 0 && $0.direction == .firstPointAgainstSecondEdge }

        XCTAssertNotNil(contact)
        XCTAssertEqual(contact?.edgeStartIndex, 0)
        XCTAssertEqual(contact?.edgeEndIndex, 1)
        XCTAssertEqual(try XCTUnwrap(contact).barycentric, 0.25, accuracy: 0.000_01)
        XCTAssertEqual(try XCTUnwrap(contact).penetration, 1, accuracy: 0.000_01)
    }

    func testCrossingEdgesProduceContactWithoutContainedVertex() {
        let horizontal = [
            Vector2(x: -2, y: -0.5), Vector2(x: 2, y: -0.5),
            Vector2(x: 2, y: 0.5), Vector2(x: -2, y: 0.5)
        ]
        let vertical = [
            Vector2(x: -0.5, y: -2), Vector2(x: 0.5, y: -2),
            Vector2(x: 0.5, y: 2), Vector2(x: -0.5, y: 2)
        ]

        let contacts = ContourContactReference.contacts(first: horizontal, second: vertical)

        XCTAssertTrue(contacts.contains { $0.direction == .edgeCrossing })
        XCTAssertEqual(contacts, contacts.sorted { $0.sourceID < $1.sourceID })
    }

    func testConcaveContourClassifiesOnlyActualInterior() {
        let concave = [
            Vector2(x: 0, y: 0), Vector2(x: 4, y: 0), Vector2(x: 4, y: 1),
            Vector2(x: 1, y: 1), Vector2(x: 1, y: 4), Vector2(x: 0, y: 4)
        ]

        XCTAssertTrue(ContourContactReference.contains(Vector2(x: 0.5, y: 3), contour: concave))
        XCTAssertFalse(ContourContactReference.contains(Vector2(x: 3, y: 3), contour: concave))
    }

    func testDegenerateSegmentReturnsFiniteNearestPoint() {
        let nearest = ContourContactReference.nearestPoint(
            to: Vector2(x: 3, y: 4),
            segmentStart: Vector2(x: 1, y: 1),
            segmentEnd: Vector2(x: 1, y: 1)
        )

        XCTAssertEqual(nearest.point, Vector2(x: 1, y: 1))
        XCTAssertEqual(nearest.barycentric, 0)
        XCTAssertTrue(nearest.distance.isFinite)
    }

    private func square(min: Vector2, max: Vector2) -> [Vector2] {
        [min, Vector2(x: max.x, y: min.y), max, Vector2(x: min.x, y: max.y)]
    }
}
