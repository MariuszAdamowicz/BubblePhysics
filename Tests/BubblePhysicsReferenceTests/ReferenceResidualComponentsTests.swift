import XCTest
@testable import BubblePhysicsReference

final class ReferenceResidualComponentsTests: XCTestCase {
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
}
