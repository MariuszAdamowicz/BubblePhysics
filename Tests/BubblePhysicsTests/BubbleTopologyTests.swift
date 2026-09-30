import XCTest
@testable import BubblePhysics

final class BubbleTopologyTests: XCTestCase {
    func testRegularBubbleDerivesBoundaryCountFromPerimeter() {
        let bubble = BubbleTopology.regular(
            id: BubbleID(rawValue: 1), center: .zero, restArea: .pi * 100,
            maxBoundarySegmentLength: 10
        )

        XCTAssertEqual(bubble.boundaryPoints.count, 8)
    }

    func testRegularBubbleUsesMinimumSafeBoundaryCount() {
        let bubble = BubbleTopology.regular(
            id: BubbleID(rawValue: 1), center: .zero, restArea: .pi,
            maxBoundarySegmentLength: 100
        )

        XCTAssertEqual(bubble.boundaryPoints.count, 8)
    }

    func testRegularBubblePreservesRequestedRestAreaAndMaterialAxis() {
        let bubble = BubbleTopology.regular(
            id: BubbleID(rawValue: 1), center: Vector2(x: 5, y: 8), restArea: .pi * 25,
            maxBoundarySegmentLength: 4
        )

        XCTAssertEqual(bubble.restArea, .pi * 25, accuracy: 0.0001)
        XCTAssertEqual(bubble.pose.materialAxis.x, 1, accuracy: 0.0001)
        XCTAssertEqual(bubble.pose.materialAxis.y, 0, accuracy: 0.0001)
    }

    func testRemesherInsertsPointForOverlongBoundarySegment() {
        var bubble = BubbleTopology.regular(
            id: BubbleID(rawValue: 1), center: .zero, restArea: .pi * 100,
            maxBoundarySegmentLength: 10
        )
        bubble.boundaryPoints[0] = Vector2(x: 30, y: 0)

        XCTAssertTrue(BoundaryRemesher(maxSegmentLength: 10, shrinkThreshold: 4).refineIfNeeded(&bubble))
        XCTAssertGreaterThan(bubble.boundaryPoints.count, 8)
    }

    func testRemesherRemovesOnlyPersistentlyShortSegment() {
        var bubble = BubbleTopology.regular(
            id: BubbleID(rawValue: 1), center: .zero, restArea: .pi * 100,
            maxBoundarySegmentLength: 10
        )
        bubble.boundaryPoints.insert(bubble.boundaryPoints[0], at: 1)
        let remesher = BoundaryRemesher(maxSegmentLength: 10, shrinkThreshold: 4)

        XCTAssertTrue(remesher.coarsenIfNeeded(&bubble))
        XCTAssertEqual(bubble.boundaryPoints.count, 8)
    }
}
