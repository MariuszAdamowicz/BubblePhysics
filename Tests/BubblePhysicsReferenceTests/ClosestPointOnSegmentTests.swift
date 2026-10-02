import XCTest
@testable import BubblePhysicsReference

final class ClosestPointOnSegmentTests: XCTestCase {
    private let horizontal = ReferenceSegmentEndpoints(
        a: ReferenceVector2(x: 0, y: 0),
        b: ReferenceVector2(x: 10, y: 0)
    )

    func testProjectionInsideSegmentReturnsInteriorQ() {
        let result = closestPoint(to: ReferenceVector2(x: 5, y: 3), on: horizontal)

        XCTAssertEqual(result.point, ReferenceVector2(x: 5, y: 0))
        XCTAssertEqual(result.t, 0.5)
        XCTAssertEqual(result.distanceSquared, 9)
    }

    func testProjectionBeforeSegmentReturnsA() {
        let result = closestPoint(to: ReferenceVector2(x: -2, y: 3), on: horizontal)

        XCTAssertEqual(result.point, horizontal.a)
        XCTAssertEqual(result.t, 0)
        XCTAssertEqual(result.distanceSquared, 13)
    }

    func testProjectionAfterSegmentReturnsB() {
        let result = closestPoint(to: ReferenceVector2(x: 12, y: 4), on: horizontal)

        XCTAssertEqual(result.point, horizontal.b)
        XCTAssertEqual(result.t, 1)
        XCTAssertEqual(result.distanceSquared, 20)
    }

    func testZeroLengthSegmentBehavesAsPoint() {
        let endpoint = ReferenceVector2(x: 1, y: 2)
        let result = closestPoint(
            to: ReferenceVector2(x: 4, y: 6),
            on: ReferenceSegmentEndpoints(a: endpoint, b: endpoint)
        )

        XCTAssertEqual(result.point, endpoint)
        XCTAssertEqual(result.t, 0)
        XCTAssertEqual(result.distanceSquared, 25)
        XCTAssertTrue(result.distanceSquared.isFinite)
    }
}
