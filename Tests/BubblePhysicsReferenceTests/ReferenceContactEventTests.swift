import XCTest
@testable import BubblePhysicsReference

final class ReferenceContactEventTests: XCTestCase {
    func testGroupsAreOrderedByEarliestTime() {
        let result = groups(events: [event(0.7, 7), event(0.2, 2), event(0.5, 5)])

        XCTAssertEqual(result.groups.map(\.time), [0.2, 0.5, 0.7])
    }

    func testEventsWithinToleranceShareOneGroup() {
        let result = groups(events: [event(0.2, 2), event(0.200009, 1)])

        XCTAssertEqual(result.groups.count, 1)
        XCTAssertEqual(result.groups[0].events.map(\.contactID.rawValue), [1, 2])
    }

    func testEventsWithinGroupAreDeterministicallyOrderedByID() {
        let result = groups(events: [event(0.2, 9), event(0.2, 3), event(0.2, 7)])

        XCTAssertEqual(result.groups[0].events.map(\.contactID.rawValue), [3, 7, 9])
    }

    func testEventExactlyAtFrameEndIsIncluded() {
        let result = groups(events: [event(1, 1)], frameDuration: 1)

        XCTAssertEqual(result.groups, [
            .init(time: 1, events: [event(1, 1)])
        ])
    }

    func testNegativeNonFiniteAndAfterFrameEventsAreRejected() {
        let result = groups(events: [
            event(-0.1, 1), event(.nan, 2), event(.infinity, 3), event(1.01, 4), event(0.4, 5)
        ])

        XCTAssertEqual(result.groups.flatMap(\.events).map(\.contactID.rawValue), [5])
    }

    func testGroupLimitReturnsOnlyEightGroupsAndSetsFlag() {
        let events = (0..<9).map { event(Float($0) * 0.1, UInt64($0)) }

        let result = groups(events: events, limit: 8)

        XCTAssertEqual(result.groups.count, 8)
        XCTAssertTrue(result.didReachLimit)
    }

    func testConfigurationProvidesSanitizedEventDefaults() {
        var configuration = ReferenceConfiguration.default
        configuration.simultaneousEventTolerance = -.infinity
        configuration.maximumEventGroups = 0

        XCTAssertEqual(configuration.sanitized.simultaneousEventTolerance, 1e-5)
        XCTAssertEqual(configuration.sanitized.maximumEventGroups, 1)
    }

    private func groups(
        events: [ReferenceContactEvent],
        frameDuration: Float = 1,
        tolerance: Float = 1e-5,
        limit: Int = 8
    ) -> (groups: [ReferenceContactEventGroup], didReachLimit: Bool) {
        ReferenceContactEventQueue.groups(
            events: events,
            frameDuration: frameDuration,
            simultaneousTolerance: tolerance,
            limit: limit
        )
    }

    private func event(_ time: Float, _ id: UInt64) -> ReferenceContactEvent {
        .init(time: time, contactID: .init(rawValue: id))
    }
}
