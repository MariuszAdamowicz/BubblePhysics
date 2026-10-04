import XCTest
@testable import BubblePhysicsReference

final class ReferenceConvergenceScenarioTests: XCTestCase {
    func testConvergenceScenesBuildExpectedDeterministicWorlds() throws {
        for (scene, expectedBubbleCount) in [
            (ReferenceConvergenceScene.interactive24, 24),
            (.stress300, 300),
        ] {
            let scenario = ReferenceConvergenceScenario(scene: scene, seed: 0xB0BB1E, newtonIterationLimit: 8)
            let first = try scenario.makeWorld()
            let second = try scenario.makeWorld()

            XCTAssertEqual(first.bubbles.count, expectedBubbleCount)
            XCTAssertEqual(first.segments.count, 7)
            XCTAssertEqual(first.bubbles, second.bubbles)
            XCTAssertEqual(first.segments, second.segments)
            XCTAssertEqual(Set(first.segments.compactMap(\.ownerID)), [ReferenceConvergenceScenario.polygonOwnerID])
            XCTAssertEqual(first.segments.filter { $0.ownerID == ReferenceConvergenceScenario.polygonOwnerID }.count, 3)
        }
    }

    func testPolygonTrajectoryDependsOnlyOnStepNumber() {
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, seed: 123, newtonIterationLimit: 4)
        for step in [0, 1, 120] {
            XCTAssertEqual(scenario.polygonCenter(atStep: step), scenario.polygonCenter(atStep: step))
        }
        XCTAssertNotEqual(scenario.polygonCenter(atStep: 0), scenario.polygonCenter(atStep: 120))
    }

    func testFreshWorldsForEveryLimitStartIdenticallyApartFromConfiguration() throws {
        let limits = [4, 8, 12, 16]
        let worlds = try limits.map {
            try ReferenceConvergenceScenario(scene: .stress300, seed: 77, newtonIterationLimit: $0).makeWorld()
        }

        for world in worlds.dropFirst() {
            XCTAssertEqual(world.bubbles, worlds[0].bubbles)
            XCTAssertEqual(world.segments, worlds[0].segments)
        }
        XCTAssertEqual(worlds.map(\.configuration.solverIterations), limits)
    }
}
