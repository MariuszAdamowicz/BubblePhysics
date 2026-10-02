import XCTest
@testable import BubblePhysics

final class RadialFrameStepScheduleTests: XCTestCase {
    func testFortyMillisecondDisplayFrameProducesFivePhysicsSteps() {
        let schedule = RadialFrameStepSchedule.make(
            previousTime: 10, currentTime: 10.040,
            fixedStep: 1.0 / 120.0, maximumStepCount: 8
        )

        XCTAssertEqual(schedule.count, 5)
        XCTAssertEqual(schedule.deltaTime, 0.008, accuracy: 0.000_001)
        XCTAssertEqual(schedule.sampleTimes[0], 10.008, accuracy: 0.000_001)
        XCTAssertEqual(schedule.sampleTimes[4], 10.040, accuracy: 0.000_001)
    }

    func testLongDisplayStallIsBoundedWithoutSlowingFollowingFrames() {
        let schedule = RadialFrameStepSchedule.make(
            previousTime: 4, currentTime: 5,
            fixedStep: 1.0 / 120.0, maximumStepCount: 8
        )

        XCTAssertEqual(schedule.count, 8)
        XCTAssertEqual(schedule.sampleTimes[7], 5, accuracy: 0.000_001)
        XCTAssertEqual(schedule.deltaTime, 1.0 / 120.0, accuracy: 0.000_001)
    }
}
