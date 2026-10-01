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
}
