import XCTest
@testable import BubblePhysicsReference

final class ReferenceVisualSceneTests: XCTestCase {
    func testFactoryBuildsFortyVariedBubblesFourWallsAndOneTriangle() throws {
        let scene = try ReferenceVisualSceneFactory.make()

        XCTAssertEqual(scene.world.bubbles.count, 40)
        XCTAssertEqual(scene.world.segments.count, 7)
        XCTAssertEqual(scene.world.segments.prefix(4).compactMap(\.collisionMode.allowedSide).count, 4)
        XCTAssertTrue(scene.world.segments.suffix(3).allSatisfy { $0.collisionMode == .twoSided })
        XCTAssertEqual(Set(scene.world.segments.suffix(3).compactMap(\.ownerID)), [scene.triangleOwnerID])

        let radii = scene.world.bubbles.map(\.targetRadius)
        XCTAssertLessThanOrEqual(try XCTUnwrap(radii.min()), 8)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(radii.max()), 60)
        XCTAssertGreaterThanOrEqual(Set(radii).count, 6)
    }
}
