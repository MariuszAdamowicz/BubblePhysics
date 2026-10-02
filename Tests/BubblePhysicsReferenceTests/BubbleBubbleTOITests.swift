import XCTest
@testable import BubblePhysicsReference

final class BubbleBubbleTOITests: XCTestCase {
    func testMovingBubbleHitsStationaryBubbleAtExpectedFraction() throws {
        let a = try bubble(id: 1, from: .init(x: 0, y: 0), to: .init(x: 10, y: 0), radius: 2)
        let b = try bubble(id: 2, from: .init(x: 10, y: 0), to: .init(x: 10, y: 0), radius: 2)

        guard case let .impact(fraction, normal, point) = ReferenceCCD.bubbleBubble(a, b) else {
            return XCTFail("Expected impact")
        }

        XCTAssertEqual(fraction, 0.6, accuracy: 0.00001)
        XCTAssertEqual(normal, ReferenceVector2(x: 1, y: 0))
        XCTAssertEqual(point.x, 8, accuracy: 0.00001)
    }

    func testParallelMotionDoesNotCollide() throws {
        let a = try bubble(id: 1, from: .init(x: 0, y: 0), to: .init(x: 10, y: 0), radius: 2)
        let b = try bubble(id: 2, from: .init(x: 0, y: 10), to: .init(x: 10, y: 10), radius: 2)

        XCTAssertEqual(ReferenceCCD.bubbleBubble(a, b), .none)
    }

    func testInitialPenetrationIsReportedWithoutAdvancingTime() throws {
        let a = try bubble(id: 1, from: .init(x: 0, y: 0), to: .init(x: 1, y: 0), radius: 2)
        let b = try bubble(id: 2, from: .init(x: 3, y: 0), to: .init(x: 3, y: 0), radius: 2)

        guard case let .initialOverlap(normal, point) = ReferenceCCD.bubbleBubble(a, b) else {
            return XCTFail("Expected initial overlap")
        }

        XCTAssertEqual(normal, ReferenceVector2(x: 1, y: 0))
        XCTAssertEqual(point.x, 2, accuracy: 0.00001)
    }

    func testTwoMovingCentersUseRelativeVelocity() throws {
        let a = try bubble(id: 1, from: .init(x: 0, y: 0), to: .init(x: 10, y: 0), radius: 2)
        let b = try bubble(id: 2, from: .init(x: 20, y: 0), to: .init(x: 10, y: 0), radius: 2)

        guard case let .impact(fraction, _, _) = ReferenceCCD.bubbleBubble(a, b) else {
            return XCTFail("Expected impact")
        }

        XCTAssertEqual(fraction, 0.8, accuracy: 0.00001)
    }

    private func bubble(
        id: Int,
        from: ReferenceVector2,
        to: ReferenceVector2,
        radius: Float
    ) throws -> ReferenceBubble {
        var bubble = try ReferenceBubble(id: .init(rawValue: id), center: from, mass: 1, targetRadius: radius)
        bubble.previousCenter = from
        bubble.center = to
        return bubble
    }
}
