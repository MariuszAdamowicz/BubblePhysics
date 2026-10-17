import BubblePhysicsModel
@testable import BubblePhysicsRuntime
import XCTest

final class EventCompactorTests: XCTestCase {
    func testDriveBlockedIsEmittedOnEntryAndFeedbackStaysContinuous() throws {
        let config = try WorldConfiguration(simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]))
        var state = RuntimeState(configuration: config)
        let id = ObjectID(rawValue: 1), blocker = ObjectID(rawValue: 2)
        let descriptor = try BubbleDescriptor(id: id, position: .zero, targetRadius: 1,
            physicsMaterialID: PhysicsMaterialID(rawValue: 1), renderStyleID: RenderStyleID(rawValue: 1),
            eventInterest: .driveBlocked)
        state.objects[id] = RuntimeObject(.bubble(descriptor))
        let feedback = DriveFeedback(objectID: id, playerDriveID: nil, target: [3, 0], achievedPoint: .zero,
            blockingContact: DriveBlockingContact(objectID: blocker, point: [1, 0], normal: [-1, 0]), isStopped: false)
        let first = EventCompactor.finish([], overflow: WorldEventOverflow(), feedback: [feedback], state: state,
            previousBlockers: [:])
        XCTAssertEqual(first.events, [.driveBlocked(id, by: blocker, point: [1, 0])])
        let second = EventCompactor.finish([], overflow: WorldEventOverflow(), feedback: [feedback], state: state,
            previousBlockers: first.blockers)
        XCTAssertTrue(second.events.isEmpty)
        XCTAssertEqual(second.blockers[id], blocker)
    }
}
