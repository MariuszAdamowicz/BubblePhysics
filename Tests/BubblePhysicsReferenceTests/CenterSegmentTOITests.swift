import XCTest
@testable import BubblePhysicsReference

final class CenterSegmentTOITests: XCTestCase {
    func testMovingCenterCrossesStaticSegment() throws {
        let bubble = try movingBubble(from: .init(x: -2, y: 0), to: .init(x: 2, y: 0))
        let segment = ReferenceSegment.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -2), b: .init(x: 0, y: 2))
        assertImpact(ReferenceCenterSegmentTOI.firstIntersection(bubble: bubble, segment: segment, tolerance: 0.0001), fraction: 0.5)
    }

    func testMovingSegmentCrossesStaticCenter() throws {
        let bubble = try movingBubble(from: .zero, to: .zero)
        let segment = ReferenceSegment.kinematicSegment(id: .init(rawValue: 1),
            previousA: .init(x: -2, y: -1), previousB: .init(x: -2, y: 1),
            currentA: .init(x: 2, y: -1), currentB: .init(x: 2, y: 1))
        assertImpact(ReferenceCenterSegmentTOI.firstIntersection(bubble: bubble, segment: segment, tolerance: 0.0001), fraction: 0.5)
    }

    func testRotatingSegmentCrossesCenter() throws {
        let bubble = try movingBubble(from: .init(x: 0, y: 1), to: .init(x: 0, y: 1))
        let segment = ReferenceSegment.kinematicSegment(id: .init(rawValue: 1),
            previousA: .init(x: -2, y: 0), previousB: .init(x: 2, y: 0),
            currentA: .init(x: 0, y: -2), currentB: .init(x: 0, y: 2))
        if case .impact = ReferenceCenterSegmentTOI.firstIntersection(bubble: bubble, segment: segment, tolerance: 0.0001) {} else {
            XCTFail("Expected rotating segment impact")
        }
    }

    func testMovingEndpointHitIsIncluded() throws {
        let bubble = try movingBubble(from: .init(x: 0, y: 0), to: .init(x: 0, y: 0))
        let segment = ReferenceSegment.kinematicSegment(id: .init(rawValue: 1),
            previousA: .init(x: -1, y: -1), previousB: .init(x: 2, y: -1),
            currentA: .init(x: 0, y: 0), currentB: .init(x: 2, y: 0))
        if case .impact = ReferenceCenterSegmentTOI.firstIntersection(bubble: bubble, segment: segment, tolerance: 0.0001) {} else {
            XCTFail("Expected endpoint impact")
        }
    }

    func testLineCrossingOutsideFiniteSegmentIsNone() throws {
        let bubble = try movingBubble(from: .init(x: -2, y: 3), to: .init(x: 2, y: 3))
        let segment = ReferenceSegment.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -1), b: .init(x: 0, y: 1))
        XCTAssertEqual(ReferenceCenterSegmentTOI.firstIntersection(bubble: bubble, segment: segment, tolerance: 0.0001), .none)
    }

    func testTangentialPathWithoutSideChangeIsNone() throws {
        let bubble = try movingBubble(from: .init(x: -2, y: 0), to: .init(x: 2, y: 0))
        let segment = ReferenceSegment.staticSegment(id: .init(rawValue: 1), a: .init(x: -3, y: 0), b: .init(x: 3, y: 0))
        XCTAssertEqual(ReferenceCenterSegmentTOI.firstIntersection(bubble: bubble, segment: segment, tolerance: 0.0001), .none)
    }

    private func movingBubble(from: ReferenceVector2, to: ReferenceVector2) throws -> ReferenceBubble {
        var bubble = try ReferenceBubble(id: .init(rawValue: 1), center: to, mass: 1, targetRadius: 1)
        bubble.previousCenter = from
        return bubble
    }

    private func assertImpact(_ result: TimeOfImpactResult, fraction: Float) {
        guard case let .impact(actual, normal, point) = result else { return XCTFail("Expected impact") }
        XCTAssertEqual(actual, fraction, accuracy: 0.0001)
        XCTAssertTrue(normal.isFinite)
        XCTAssertTrue(point.isFinite)
    }
}
