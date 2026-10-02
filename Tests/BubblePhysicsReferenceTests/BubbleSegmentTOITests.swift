import XCTest
@testable import BubblePhysicsReference

final class BubbleSegmentTOITests: XCTestCase {
    func testTranslatingSegmentHitsBubbleAlongItsInterior() throws {
        let bubble = try stationaryBubble(x: 0, y: 0, radius: 1)
        let segment = ReferenceSegment.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .init(x: -5, y: -5), previousB: .init(x: 5, y: -5),
            currentA: .init(x: -5, y: 5), currentB: .init(x: 5, y: 5)
        )

        let result = ReferenceCCD.bubbleSegment(bubble, segment, configuration: .default)
        guard case let .impact(fraction, normal, _) = result.timeOfImpact else {
            return XCTFail("Expected interior impact, got \(result)")
        }

        XCTAssertEqual(fraction, 0.4, accuracy: 0.0001)
        XCTAssertEqual(normal, ReferenceVector2(x: 0, y: 1))
    }

    func testBubbleHitsSegmentEndpoint() throws {
        var bubble = try stationaryBubble(x: -5, y: -1, radius: 1)
        bubble.center = ReferenceVector2(x: 5, y: -1)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 1),
            a: .init(x: 0, y: 0),
            b: .init(x: 0, y: 4)
        )

        let result = ReferenceCCD.bubbleSegment(bubble, segment, configuration: .default)
        guard case let .impact(fraction, _, point) = result.timeOfImpact else {
            return XCTFail("Expected endpoint impact")
        }

        XCTAssertEqual(fraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(point, ReferenceVector2(x: 0, y: 0))
    }

    func testRelativeMotionIncludesBubbleAndSegment() throws {
        var bubble = try stationaryBubble(x: 0, y: 4, radius: 1)
        bubble.center = ReferenceVector2(x: 0, y: 2)
        let segment = ReferenceSegment.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .init(x: -5, y: -4), previousB: .init(x: 5, y: -4),
            currentA: .init(x: -5, y: 4), currentB: .init(x: 5, y: 4)
        )

        let result = ReferenceCCD.bubbleSegment(bubble, segment, configuration: .default)
        guard case let .impact(fraction, _, _) = result.timeOfImpact else {
            return XCTFail("Expected relative-motion impact")
        }

        XCTAssertEqual(fraction, 0.7, accuracy: 0.001)
    }

    func testRotatingSegmentFindsContactByConservativeAdvancement() throws {
        let bubble = try stationaryBubble(x: 2, y: 2, radius: 0.5)
        let segment = ReferenceSegment.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .zero, previousB: .init(x: 4, y: 0),
            currentA: .zero, currentB: .init(x: 0, y: 4)
        )

        let result = ReferenceCCD.bubbleSegment(bubble, segment, configuration: .default)

        guard case let .impact(fraction, _, _) = result.timeOfImpact else {
            return XCTFail("Expected rotating contact, got \(result)")
        }
        XCTAssertGreaterThan(fraction, 0)
        XCTAssertLessThan(fraction, 1)
        XCTAssertFalse(result.didExhaustBudget)
    }

    func testTwoSidedSegmentAllowsSideChangeOutsideEndpoint() throws {
        var bubble = try stationaryBubble(x: -2, y: 1, radius: 0.5)
        bubble.center = .init(x: -2, y: -1)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 1),
            a: .init(x: 0, y: 0), b: .init(x: 4, y: 0),
            collisionMode: .twoSided
        )

        let result = ReferenceCCD.bubbleSegment(bubble, segment, configuration: .default)

        XCTAssertEqual(result.timeOfImpact, .none)
        XCTAssertFalse(result.requiresSideCorrection)
    }

    func testOneSidedSegmentReportsForbiddenSideChangeOutsideEndpoint() throws {
        var bubble = try stationaryBubble(x: -2, y: 1, radius: 0.5)
        bubble.center = .init(x: -2, y: -1)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 1),
            a: .init(x: 0, y: 0), b: .init(x: 4, y: 0),
            collisionMode: .oneSided(allowedSide: 1)
        )

        let result = ReferenceCCD.bubbleSegment(bubble, segment, configuration: .default)

        XCTAssertEqual(result.timeOfImpact, .none)
        XCTAssertTrue(result.requiresSideCorrection)
    }

    private func stationaryBubble(x: Float, y: Float, radius: Float) throws -> ReferenceBubble {
        try ReferenceBubble(id: .init(rawValue: 1), center: .init(x: x, y: y), mass: 1, targetRadius: radius)
    }
}
