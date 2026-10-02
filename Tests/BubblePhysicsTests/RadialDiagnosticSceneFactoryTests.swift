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

    func testDiagnosticMaterialRecoversFromDeformationWithinHalfSecond() throws {
        var bubble = try XCTUnwrap(RadialDiagnosticSceneFactory.make().world.bubbles.first { $0.targetRadius == 160 })
        bubble.birthProgress = 1
        for index in bubble.sensors.indices {
            bubble.sensors[index].length = index.isMultiple(of: 2) ? 80 : 160
            bubble.sensors[index].targetLength = 160
        }

        for _ in 0..<60 {
            RadialBubbleIntegrator.step(
                state: &bubble, load: .zero(sensorCount: bubble.sensors.count),
                deltaTime: 1 / 120
            )
        }

        XCTAssertLessThan(bubble.sensors.map { abs($0.length - 160) }.max() ?? .infinity, 8)
    }
}
