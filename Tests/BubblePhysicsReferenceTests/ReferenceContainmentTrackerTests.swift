import XCTest
@testable import BubblePhysicsReference

final class ReferenceContainmentTrackerTests: XCTestCase {
    func testTrackerCountsConsecutiveFullContainmentAndResetsAfterSeparation() throws {
        var tracker = ReferenceContainmentTracker(positionTolerance: 0.001)
        let contained = [try bubble(1, x: 0, radius: 10), try bubble(2, x: 2, radius: 3)]
        let separated = [try bubble(1, x: 0, radius: 10), try bubble(2, x: 20, radius: 3)]

        tracker.observe(contained)
        tracker.observe(contained)
        tracker.observe(separated)

        XCTAssertEqual(tracker.maximumConsecutiveFrames, 2)
        tracker.observe(contained)
        XCTAssertEqual(tracker.maximumConsecutiveFrames, 2)
    }

    func testTrackerIgnoresOrdinaryOverlap() throws {
        var tracker = ReferenceContainmentTracker(positionTolerance: 0.001)
        tracker.observe([try bubble(1, x: 0, radius: 10), try bubble(2, x: 11, radius: 3)])
        tracker.observe([try bubble(1, x: 0, radius: 10), try bubble(2, x: 11, radius: 3)])
        XCTAssertEqual(tracker.maximumConsecutiveFrames, 0)
    }

    private func bubble(_ id: Int, x: Float, radius: Float) throws -> ReferenceBubble {
        try ReferenceBubble(
            id: .init(rawValue: id), center: .init(x: x, y: 0),
            mass: 1, targetRadius: radius
        )
    }
}
