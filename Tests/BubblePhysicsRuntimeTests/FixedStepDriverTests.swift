import XCTest
@testable import BubblePhysicsRuntime

final class FixedStepDriverTests: XCTestCase {
    func testAccumulatesTimeWithoutConsumingAnIncompleteStep() {
        var driver = FixedStepDriver(fixedTimeStep: 0.125)
        XCTAssertTrue(driver.accumulate(0.0625))
        XCTAssertFalse(driver.canStep)
        XCTAssertEqual(driver.completedSteps, 0)
        XCTAssertTrue(driver.accumulate(0.3125))
        for _ in 0..<3 {
            XCTAssertTrue(driver.canStep)
            driver.completeStep()
        }
        XCTAssertFalse(driver.canStep)
        XCTAssertEqual(driver.simulationTime, 0.375)
        XCTAssertEqual(driver.backlogSeconds, 0)
    }

    func testPersistentBacklogIsReportedWithoutChangingConfiguredStep() {
        var driver = FixedStepDriver(fixedTimeStep: 0.125, maximumStepsPerAdvance: 2)
        for expectedBacklog in [0.75, 1.5] {
            XCTAssertTrue(driver.accumulate(1))
            for _ in 0..<driver.maximumStepsPerAdvance { driver.completeStep() }
            driver.finishAdvance()
            XCTAssertEqual(driver.backlogSeconds, expectedBacklog)
            XCTAssertEqual(driver.fixedTimeStep, 0.125)
        }
        XCTAssertEqual(driver.consecutiveBackloggedAdvances, 2)
        while driver.canStep { driver.completeStep() }
        driver.finishAdvance()
        XCTAssertEqual(driver.consecutiveBackloggedAdvances, 0)
        XCTAssertEqual(driver.simulationTime, 2)
    }

    func testDecimalPresentationIntervalsDoNotLoseACompleteStepToRounding() {
        var driver = FixedStepDriver(fixedTimeStep: 0.1)
        XCTAssertTrue(driver.accumulate(0.3))
        var steps = 0
        while driver.canStep { driver.completeStep(); steps += 1 }
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(driver.backlogSeconds, 0, accuracy: 1e-15)
    }

    func testInvalidTimeAndOverflowLeaveAccumulatorUntouched() {
        var driver = FixedStepDriver(fixedTimeStep: 0.125)
        XCTAssertTrue(driver.accumulate(0.0625))
        for invalid in [-1, Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(driver.accumulate(invalid))
            XCTAssertEqual(driver.backlogSeconds, 0.0625)
        }
        XCTAssertTrue(driver.accumulate(Double.greatestFiniteMagnitude))
        XCTAssertFalse(driver.accumulate(Double.greatestFiniteMagnitude))
        XCTAssertTrue(driver.backlogSeconds.isFinite)
    }

    func testRoundingToleranceCannotTurnHalfOfASubnormalStepIntoAFullStep() {
        var driver = FixedStepDriver(fixedTimeStep: Double.leastNonzeroMagnitude * 8)
        XCTAssertTrue(driver.accumulate(Double.leastNonzeroMagnitude * 4))
        XCTAssertFalse(driver.canStep)
    }
}
