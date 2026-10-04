import XCTest
@testable import BubblePhysicsReference

final class ReferenceBenchmarkFrameTests: XCTestCase {
    func testFrameAdvancesDeterministicPolygonAndPreparesEveryContour() throws {
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, seed: 1, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()

        let result = ReferenceBenchmarkFrame.run(world: &world, scenario: scenario, step: 7)

        XCTAssertEqual(result.preparedBubbles.count, 24)
        XCTAssertEqual(result.contourPointCount, result.preparedBubbles.reduce(0) { $0 + $1.contour.count })
        XCTAssertTrue(result.preparedBubbles.allSatisfy { !$0.contour.isEmpty })
        let polygon = world.segments.filter { $0.ownerID == ReferenceConvergenceScenario.polygonOwnerID }
        XCTAssertTrue(polygon.allSatisfy { $0.currentA != $0.previousA || $0.currentB != $0.previousB })
    }

    func testFullFrameTimingContainsSimulationContourAndPreparation() throws {
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, seed: 2, newtonIterationLimit: 4)
        var world = try scenario.makeWorld()
        let result = ReferenceBenchmarkFrame.run(world: &world, scenario: scenario, step: 0)

        for value in [result.simulationMilliseconds, result.contourMilliseconds,
                      result.renderPreparationMilliseconds, result.fullFrameMilliseconds] {
            XCTAssertTrue(value.isFinite)
            XCTAssertGreaterThanOrEqual(value, 0)
        }
        XCTAssertGreaterThanOrEqual(result.fullFrameMilliseconds, result.simulationMilliseconds)
    }

    func testRepeatedIdenticalRunsProduceEqualPhysicsAndGeometry() throws {
        let scenario = ReferenceConvergenceScenario(scene: .interactive24, seed: 3, newtonIterationLimit: 4)
        var first = try scenario.makeWorld()
        var second = try scenario.makeWorld()

        let firstResult = ReferenceBenchmarkFrame.run(world: &first, scenario: scenario, step: 12)
        let secondResult = ReferenceBenchmarkFrame.run(world: &second, scenario: scenario, step: 12)

        XCTAssertEqual(first.bubbles, second.bubbles)
        XCTAssertEqual(first.contacts, second.contacts)
        XCTAssertEqual(firstResult.worldReport.solver, secondResult.worldReport.solver)
        XCTAssertEqual(firstResult.worldReport.candidatePairCount, secondResult.worldReport.candidatePairCount)
        XCTAssertEqual(firstResult.worldReport.generatedContactCount, secondResult.worldReport.generatedContactCount)
        XCTAssertEqual(firstResult.worldReport.toiTestCount, secondResult.worldReport.toiTestCount)
        XCTAssertEqual(firstResult.preparedBubbles, secondResult.preparedBubbles)
    }
}
