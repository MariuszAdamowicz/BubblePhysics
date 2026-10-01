import XCTest
@testable import BubblePhysics

final class PrototypeSceneTests: XCTestCase {
    func testInspectionSceneContainsFortyBubblesAndOneKinematicTriangle() throws {
        let snapshot = try PrototypeSceneFactory.make(.inspection).simulationSnapshot()

        XCTAssertEqual(snapshot.bubbles.count, 40)
        XCTAssertEqual(snapshot.polygons.count, 1)
        XCTAssertEqual(snapshot.polygons[0].mode, .kinematic)
    }

    func testStressSceneContainsThreeHundredBubbles() throws {
        let snapshot = try PrototypeSceneFactory.make(.stress).simulationSnapshot()

        XCTAssertEqual(snapshot.bubbles.count, 300)
    }

    func testInspectionSceneUsesExactMultiscaleValueDistribution() {
        XCTAssertEqual(counts(PrototypeSceneFactory.seeds(for: .inspection)), [2: 20, 4: 8, 8: 5, 16: 3, 32: 2, 64: 1, 512: 1])
    }

    func testStressSceneUsesExactMultiscaleValueDistribution() {
        XCTAssertEqual(counts(PrototypeSceneFactory.seeds(for: .stress)), [2: 163, 4: 64, 8: 32, 16: 16, 32: 8, 64: 6, 128: 4, 256: 3, 512: 2, 1024: 1, 2048: 1])
    }

    func testRestAreaScalesLinearlyWithValueAndLargestRadiusExceedsScreenWidth() throws {
        let seeds = PrototypeSceneFactory.seeds(for: .stress)
        let area2 = try XCTUnwrap(seeds.first(where: { $0.value == 2 })).restArea
        let largest = try XCTUnwrap(seeds.first(where: { $0.value == 2048 }))

        XCTAssertEqual(largest.restArea, area2 * 1024, accuracy: area2 * 0.0001)
        XCTAssertGreaterThan(sqrt(largest.restArea / .pi), PrototypeSceneFactory.bounds.maximum.x)
    }

    func testValueLabelsAreIndependentFromBubbleIdentifiers() {
        let seeds = PrototypeSceneFactory.seeds(for: .inspection)

        XCTAssertEqual(seeds.map(\.value), PrototypeSceneFactory.values(for: .inspection))
        XCTAssertNotEqual(seeds.map { $0.id.rawValue }, seeds.map(\.value))
    }

    func testLargestInspectionBubbleStartsAtTheCenterOfTheBoard() throws {
        let largest = try XCTUnwrap(PrototypeSceneFactory.seeds(for: .inspection).max { $0.value < $1.value })

        XCTAssertEqual(largest.center, Vector2(x: 187.5, y: 406))
    }

    func testSceneFactoryIsDeterministic() throws {
        let first = try PrototypeSceneFactory.make(.inspection).simulationSnapshot()
        let second = try PrototypeSceneFactory.make(.inspection).simulationSnapshot()

        XCTAssertEqual(first, second)
    }

    func testKinematicTriangleMotionIsPeriodic() {
        let motion = KinematicTriangleMotion.default
        let first = motion.sample(time: 1.25, isPaused: false)
        let repeated = motion.sample(time: 1.25 + motion.period, isPaused: false)

        XCTAssertEqual(first.position.x, repeated.position.x, accuracy: 0.0001)
        XCTAssertEqual(first.position.y, repeated.position.y, accuracy: 0.0001)
        XCTAssertEqual(first.linearVelocity.x, repeated.linearVelocity.x, accuracy: 0.0001)
        XCTAssertEqual(first.linearVelocity.y, repeated.linearVelocity.y, accuracy: 0.0001)
        XCTAssertEqual(sin(first.angleRadians), sin(repeated.angleRadians), accuracy: 0.0001)
        XCTAssertEqual(cos(first.angleRadians), cos(repeated.angleRadians), accuracy: 0.0001)
    }

    func testPausedKinematicTriangleKeepsPoseAndReportsZeroVelocity() {
        let motion = KinematicTriangleMotion.default
        let moving = motion.sample(time: 2, isPaused: false)
        let paused = motion.sample(time: 2, isPaused: true)

        XCTAssertEqual(paused.position, moving.position)
        XCTAssertEqual(paused.angleRadians, moving.angleRadians)
        XCTAssertEqual(paused.linearVelocity, .zero)
        XCTAssertEqual(paused.angularVelocity, 0)
    }

    private func counts(_ seeds: [BenchmarkBubbleSeed]) -> [Int: Int] {
        Dictionary(grouping: seeds, by: \.value).mapValues(\.count)
    }
}
