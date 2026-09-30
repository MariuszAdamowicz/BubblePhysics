import XCTest
@testable import BubblePhysics

final class BenchmarkScenarioTests: XCTestCase {
    func testIPhoneXScenarioCreatesDeterministicThreeHundredBubbleWorldWithoutNodeCap() {
        let scenario = BenchmarkScenario.iPhoneX
        var first = scenario.makeWorld()
        var second = scenario.makeWorld()

        XCTAssertEqual(scenario.seeds.count, 300)
        let firstReport = first.step()
        let secondReport = second.step()
        XCTAssertEqual(firstReport.diagnostics.bubbleCount, 300)
        XCTAssertEqual(firstReport, secondReport)
        for seed in scenario.seeds {
            let radius = sqrt(seed.restArea / .pi)
            let perimeter = 2 * .pi * radius
            let expected = max(8, Int(ceil(perimeter / scenario.configuration.maxBoundarySegmentLength)))
            XCTAssertEqual(first.bubble(seed.id)!.boundaryPoints.count, expected)
        }
    }
}
