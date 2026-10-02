import XCTest
@testable import BubblePhysics

final class RadialDiagnosticSceneFactoryTests: XCTestCase {
    func testSceneContainsSixteenBubblesAcrossAllSizeClasses() throws {
        let scene = try RadialDiagnosticSceneFactory.make()

        XCTAssertEqual(scene.world.bubbles.count, 16)
        XCTAssertEqual(scene.labels.count, 16)
        XCTAssertTrue(scene.world.bubbles.contains { (18...32).contains($0.targetRadius) })
        XCTAssertTrue(scene.world.bubbles.contains { (48...90).contains($0.targetRadius) })
        XCTAssertTrue(scene.world.bubbles.contains { $0.targetRadius == 160 })
        XCTAssertTrue(scene.world.bubbles.contains { $0.targetRadius == 430 })
    }

    func testHugeBubbleExceedsShortBoardDimension() throws {
        let scene = try RadialDiagnosticSceneFactory.make()
        let shortDimension = min(
            scene.bounds.maximum.x - scene.bounds.minimum.x,
            scene.bounds.maximum.y - scene.bounds.minimum.y
        )

        XCTAssertGreaterThan(try XCTUnwrap(scene.world.bubbles.map(\.targetRadius).max()), shortDimension)
    }

    func testBubblesStartCollapsedWithUniqueIDs() throws {
        let bubbles = try RadialDiagnosticSceneFactory.make().world.bubbles

        XCTAssertEqual(Set(bubbles.map(\.id)).count, bubbles.count)
        XCTAssertTrue(bubbles.allSatisfy { $0.birthProgress == 0 })
        XCTAssertTrue(bubbles.flatMap(\.sensors).allSatisfy { $0.length == 0 })
    }
}
