import XCTest
import Foundation
@testable import BubblePhysicsReference

final class ReferenceBenchmarkTests: XCTestCase {
    func testNamedScenariosHaveExpectedObjectCounts() throws {
        let expectations: [(ReferenceBenchmarkScenario, Int, Int)] = [
            (.twoBubbles, 2, 0),
            (.chain, 8, 0),
            (.fastSegment, 1, 1),
            (.rotatingSegment, 1, 1),
            (.triangle, 24, 3),
            (.giantBubble, 1, 4),
            (.mixedSizes(count: 37), 37, 4),
            (.filled(count: 40), 40, 4),
            (.filled(count: 300), 300, 4),
            (.filled(count: 1_000), 1_000, 4)
        ]

        for (scenario, bubbles, segments) in expectations {
            let world = try scenario.makeWorld()
            XCTAssertEqual(world.bubbles.count, bubbles, scenario.name)
            XCTAssertEqual(world.segments.count, segments, scenario.name)
        }
    }

    func testScenarioConstructionIsDeterministic() throws {
        let scenario = ReferenceBenchmarkScenario.mixedSizes(count: 300, seed: 0x2B_BA_11)
        let first = try scenario.makeWorld()
        let second = try scenario.makeWorld()
        XCTAssertEqual(first.bubbles, second.bubbles)
        XCTAssertEqual(first.segments, second.segments)
    }

    func testMeasuredReportContainsFiniteNonnegativeValues() throws {
        let report = try ReferenceBenchmarkRunner.measure(
            scenario: .filled(count: 40), warmupSteps: 2, measuredSteps: 4
        )

        XCTAssertEqual(report.measuredSteps, 4)
        XCTAssertTrue(report.frame.p50Milliseconds.isFinite)
        XCTAssertTrue(report.frame.p95Milliseconds.isFinite)
        XCTAssertGreaterThanOrEqual(report.frame.p50Milliseconds, 0)
        XCTAssertGreaterThanOrEqual(report.frame.p95Milliseconds, report.frame.p50Milliseconds)
        XCTAssertFalse(report.hasNonFiniteState)
        XCTAssertGreaterThan(report.maximumTOITests, 0)
        XCTAssertGreaterThanOrEqual(report.ccdBudgetExhaustionCount, 0)
    }

    func testBroadPhasesReturnSameCandidateCountsForFilledScenes() throws {
        for count in [300, 1_000] {
            let sweep = try ReferenceBenchmarkRunner.measure(
                scenario: .filled(count: count, broadPhase: .sweepAndPrune),
                warmupSteps: 0, measuredSteps: 1
            )
            let tree = try ReferenceBenchmarkRunner.measure(
                scenario: .filled(count: count, broadPhase: .aabbTree),
                warmupSteps: 0, measuredSteps: 1
            )
            XCTAssertEqual(sweep.maximumCandidatePairs, tree.maximumCandidatePairs)
            XCTAssertEqual(sweep.maximumGeneratedContacts, tree.maximumGeneratedContacts)
        }
    }

    func testPrintLocalBaselineWhenRequested() throws {
        guard ProcessInfo.processInfo.environment["REFERENCE_BENCHMARK_PRINT"] == "1" else {
            throw XCTSkip("Set REFERENCE_BENCHMARK_PRINT=1 to print the local baseline")
        }
        for count in [40, 300, 1_000] {
            for broadPhase in [ReferenceBroadPhaseSelection.sweepAndPrune, .aabbTree] {
                let report = try ReferenceBenchmarkRunner.measure(
                    scenario: .filled(count: count, broadPhase: broadPhase),
                    warmupSteps: 10,
                    measuredSteps: 30
                )
                print(String(format:
                    "BASELINE count=%d broad=%@ p50=%.4f p95=%.4f prediction=%.4f broadPhase=%.4f contacts=%.4f solver=%.4f candidates=%d generated=%d persistent=%d penetration=%.5f iterations=%d limits=%d ccdLimits=%d side=%d nonFinite=%@",
                    count, broadPhase.rawValue,
                    report.frame.p50Milliseconds, report.frame.p95Milliseconds,
                    report.prediction.p95Milliseconds, report.broadPhaseTiming.p95Milliseconds,
                    report.contacts.p95Milliseconds, report.solver.p95Milliseconds,
                    report.maximumCandidatePairs, report.maximumGeneratedContacts,
                    report.maximumPersistentContacts, report.maximumPenetration,
                    report.maximumSolverIterations, report.solverIterationLimitCount,
                    report.ccdBudgetExhaustionCount,
                    report.sideCorrectionCount, report.hasNonFiniteState ? "yes" : "no"
                ))
            }
        }
    }
}
