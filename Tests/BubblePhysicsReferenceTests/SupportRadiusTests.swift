import XCTest
@testable import BubblePhysicsReference

final class SupportRadiusTests: XCTestCase {
    func testBubbleWithoutDeformationsReturnsTargetRadius() throws {
        let bubble = try makeBubble(radius: 12)

        XCTAssertEqual(bubble.supportRadius(along: ReferenceVector2(x: 1, y: 0)), 12)
        XCTAssertEqual(bubble.supportRadius(along: ReferenceVector2(x: 0, y: -1)), 12)
    }

    func testSingleContactHasMaximumIndentationOnItsNormalAndFadesSmoothly() throws {
        var bubble = try makeBubble(radius: 10)
        bubble.directionalDeformations = [
            DirectionalDeformation(
                contactID: .init(rawValue: 7),
                direction: ReferenceVector2(x: 1, y: 0),
                depth: 4,
                angularWidth: .pi / 2,
                pressure: 20
            )
        ]

        XCTAssertEqual(bubble.supportRadius(along: ReferenceVector2(x: 1, y: 0)), 6, accuracy: 0.0001)
        XCTAssertEqual(bubble.supportRadius(along: ReferenceVector2(x: 1, y: 1)), 8, accuracy: 0.0001)
        XCTAssertEqual(bubble.supportRadius(along: ReferenceVector2(x: 0, y: 1)), 10, accuracy: 0.0001)
        XCTAssertEqual(bubble.supportRadius(along: ReferenceVector2(x: -1, y: 0)), 10, accuracy: 0.0001)
    }

    func testCombinedContactsNeverProduceNegativeOrNonFiniteRadius() throws {
        var bubble = try makeBubble(radius: 10)
        bubble.directionalDeformations = [
            .init(contactID: .init(rawValue: 1), direction: .init(x: 1, y: 0), depth: 8, angularWidth: .pi, pressure: 1),
            .init(contactID: .init(rawValue: 2), direction: .init(x: 1, y: 0), depth: 8, angularWidth: .pi, pressure: 1)
        ]

        let radius = bubble.supportRadius(along: ReferenceVector2(x: 1, y: 0))
        XCTAssertEqual(radius, 0)
        XCTAssertTrue(radius.isFinite)
    }

    private func makeBubble(radius: Float) throws -> ReferenceBubble {
        try ReferenceBubble(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: radius)
    }
}
