import XCTest
@testable import BubblePhysicsReference

final class SupportRadiusTests: XCTestCase {
    func testCollisionSupportAlwaysUsesNaturalRadius() throws {
        let bubble = try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 12
        )

        XCTAssertEqual(bubble.supportRadius(along: .init(x: 1, y: 0)), 12)
        XCTAssertEqual(bubble.supportRadius(along: .init(x: 0, y: -1)), 12)
        XCTAssertEqual(bubble.supportRadius(along: .zero), 12)
    }
}
