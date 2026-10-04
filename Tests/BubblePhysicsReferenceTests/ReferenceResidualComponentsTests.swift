import XCTest
@testable import BubblePhysicsReference

final class ReferenceResidualComponentsTests: XCTestCase {
    func testSummaryCountsOnlyUnconvergedIndependentIsland() {
        let contacts = [pair(id: 1, 1, 2), pair(id: 2, 3, 4)]
        let summary = ReferenceResidualComponents.summary(
            residual: [
                .init(x: 0.1, y: 0), .init(x: 0.1, y: 0),
                .init(x: 3, y: 0), .init(x: 4, y: 0),
            ],
            contacts: contacts,
            indices: [.init(rawValue: 1): 0, .init(rawValue: 2): 1, .init(rawValue: 3): 2, .init(rawValue: 4): 3],
            tolerance: 1
        )

        XCTAssertEqual(summary.componentCount, 2)
        XCTAssertEqual(summary.unconvergedCount, 1)
        XCTAssertEqual(summary.maximumNorm, 5, accuracy: 1e-6)
    }

    func testSummaryIncludesBubbleSegmentOnlyComponent() {
        let contact = ReferenceContact(
            id: .init(rawValue: 1), kind: .bubbleSegment,
            bubbleA: .init(rawValue: 7), segment: .init(rawValue: 4),
            normal: .init(x: 1, y: 0), pointQ: .zero, penetration: 1
        )
        let summary = ReferenceResidualComponents.summary(
            residual: [.init(x: 2, y: 0)], contacts: [contact],
            indices: [.init(rawValue: 7): 0], tolerance: 1
        )

        XCTAssertEqual(summary.componentCount, 1)
        XCTAssertEqual(summary.unconvergedCount, 1)
        XCTAssertEqual(summary.maximumNorm, 2, accuracy: 1e-6)
    }

    func testSummaryReturnsZerosWithoutContacts() {
        XCTAssertEqual(
            ReferenceResidualComponents.summary(
                residual: [.init(x: 99, y: 0)], contacts: [],
                indices: [.init(rawValue: 1): 0], tolerance: 0.1
            ),
            .init(componentCount: 0, unconvergedCount: 0, maximumNorm: 0)
        )
    }

    func testIndependentImprovingComponentIsAcceptedWhenAnotherGetsWorse() {
        let accepted = ReferenceResidualComponents.improvingBubbleIndices(
            current: [.init(x: 10, y: 0), .init(x: 1, y: 0)],
            trial: [.init(x: 5, y: 0), .init(x: 2, y: 0)],
            contacts: [],
            indices: [.init(rawValue: 1): 0, .init(rawValue: 2): 1]
        )

        XCTAssertEqual(accepted, [0])
    }

    func testConnectedBubblesAreAcceptedOrRejectedAsOneComponent() {
        let contact = ReferenceContact(
            id: .init(rawValue: 1), kind: .bubbleBubble,
            bubbleA: .init(rawValue: 1), bubbleB: .init(rawValue: 2),
            normal: .init(x: 1, y: 0), pointQ: .zero, penetration: 1
        )
        let indices: [ReferenceBubbleID: Int] = [
            .init(rawValue: 1): 0, .init(rawValue: 2): 1,
        ]

        let rejected = ReferenceResidualComponents.improvingBubbleIndices(
            current: [.init(x: 1, y: 0), .init(x: 1, y: 0)],
            trial: [.init(x: 0.5, y: 0), .init(x: 2, y: 0)],
            contacts: [contact], indices: indices
        )
        XCTAssertTrue(rejected.isEmpty)

        let accepted = ReferenceResidualComponents.improvingBubbleIndices(
            current: [.init(x: 3, y: 0), .init(x: 4, y: 0)],
            trial: [.init(x: 1, y: 0), .init(x: 2, y: 0)],
            contacts: [contact], indices: indices
        )
        XCTAssertEqual(accepted, [0, 1])
    }

    private func pair(id: Int, _ a: Int, _ b: Int) -> ReferenceContact {
        ReferenceContact(
            id: .init(rawValue: UInt64(id)), kind: .bubbleBubble,
            bubbleA: .init(rawValue: a), bubbleB: .init(rawValue: b),
            normal: .init(x: 1, y: 0), pointQ: .zero, penetration: 1
        )
    }
}
