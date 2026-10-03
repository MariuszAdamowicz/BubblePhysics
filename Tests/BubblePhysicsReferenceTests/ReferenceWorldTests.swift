import XCTest
@testable import BubblePhysicsReference

final class ReferenceWorldTests: XCTestCase {
    func testContactHalfwayThroughFrameActsOnlyForRemainingTime() throws {
        var world = world(timeStep: 0.4)
        world.addBubble(try bubble(1, x: 0, velocity: 10))
        world.addBubble(try bubble(2, x: 4))

        let report = world.step()

        XCTAssertEqual(report.eventGroupCount, 1)
        XCTAssertEqual(report.solverSubstepCount, 2)
        XCTAssertGreaterThan(world.bubbles[0].center.x, 2)
        XCTAssertLessThan(world.bubbles[0].velocity.x, 10)
        XCTAssertGreaterThan(world.bubbles[1].velocity.x, 0)
    }

    func testSimultaneousContactsActivateInOneDeterministicGroup() throws {
        var world = world(timeStep: 0.5)
        world.addBubble(try bubble(1, x: -4, velocity: 5))
        world.addBubble(try bubble(2, x: 0))
        world.addBubble(try bubble(3, x: 4, velocity: -5))

        let report = world.step()

        XCTAssertEqual(report.eventGroupCount, 1)
        XCTAssertEqual(world.contacts.contacts.count, 2)
        XCTAssertEqual(world.bubbles[1].center.x, 0, accuracy: 2e-3)
        XCTAssertEqual(world.contacts.contacts.map(\.id), world.contacts.contacts.map(\.id).sorted())
    }

    func testThirdContactChangesResultOfOngoingPair() throws {
        var pairWorld = world(timeStep: 0.4)
        pairWorld.addBubble(try bubble(1, x: 0, velocity: 10))
        pairWorld.addBubble(try bubble(2, x: 4))
        var chainWorld = pairWorld
        chainWorld.addBubble(try bubble(3, x: 6.2))

        _ = pairWorld.step()
        _ = chainWorld.step()

        XCTAssertGreaterThan(chainWorld.bubbles[2].velocity.x, 0)
        XCTAssertGreaterThan(
            abs(chainWorld.bubbles[1].velocity.x - pairWorld.bubbles[1].velocity.x),
            0.1
        )
    }

    func testContactExactlyAtFrameEndIsPreservedWithoutRetroactiveImpulse() throws {
        var world = world(timeStep: 0.2)
        world.addBubble(try bubble(1, x: 0, velocity: 10))
        world.addBubble(try bubble(2, x: 4))

        let report = world.step()

        XCTAssertEqual(report.eventGroupCount, 1)
        XCTAssertEqual(world.contacts.contacts.count, 1)
        XCTAssertEqual(world.bubbles[0].velocity.x, 10, accuracy: 1e-4)
        XCTAssertEqual(world.bubbles[1].velocity.x, 0, accuracy: 1e-4)
    }

    func testEventLimitIsReportedAndStateStaysFinite() throws {
        var config = baseConfiguration(timeStep: 0.4)
        config.maximumEventGroups = 1
        var world = ReferenceWorld(configuration: config, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try bubble(1, x: 0, velocity: 10))
        world.addBubble(try bubble(2, x: 3))
        world.addBubble(try bubble(3, x: 10, velocity: 10))
        world.addBubble(try bubble(4, x: 14))

        let report = world.step()

        XCTAssertTrue(report.didReachEventGroupLimit)
        XCTAssertEqual(report.eventGroupCount, 1)
        XCTAssertTrue(world.bubbles.allSatisfy { $0.center.isFinite && $0.velocity.isFinite })
    }

    func testFreeMotionUsesOneSolverIntervalWithoutEventSplit() throws {
        var world = world(timeStep: 0.25)
        world.addBubble(try bubble(1, x: 3, velocity: 4))

        let report = world.step()

        XCTAssertEqual(report.eventGroupCount, 0)
        XCTAssertEqual(report.solverSubstepCount, 1)
        XCTAssertEqual(world.bubbles[0].center.x, 4, accuracy: 1e-4)
        XCTAssertEqual(world.bubbles[0].velocity.x, 4, accuracy: 1e-4)
    }

    func testFastMovingSegmentCannotCrossBubbleCenter() throws {
        var world = world(timeStep: 1)
        world.addBubble(try bubble(1, x: 0, radius: 0.5))
        world.addSegment(.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .init(x: -2, y: -2), previousB: .init(x: -2, y: 2),
            currentA: .init(x: 2, y: -2), currentB: .init(x: 2, y: 2),
            timeStep: 1, collisionMode: .twoSided
        ))

        let report = world.step()

        XCTAssertGreaterThan(report.centerGuardCount, 0)
        let segment = world.segments[0]
        let previousNormal = ReferenceVector2(
            x: -(segment.previousB - segment.previousA).y,
            y: (segment.previousB - segment.previousA).x
        ).normalized()
        let currentNormal = ReferenceVector2(
            x: -(segment.currentB - segment.currentA).y,
            y: (segment.currentB - segment.currentA).x
        ).normalized()
        let previousSide = (ReferenceVector2.zero - segment.previousA).dot(previousNormal)
        let currentSide = (world.bubbles[0].center - segment.currentA).dot(currentNormal)
        XCTAssertGreaterThanOrEqual(previousSide * currentSide, 0)
        XCTAssertTrue(world.bubbles[0].center.isFinite)
    }

    private func world(timeStep: Float) -> ReferenceWorld {
        ReferenceWorld(
            configuration: baseConfiguration(timeStep: timeStep),
            broadPhase: SweepAndPruneBroadPhase()
        )
    }

    private func baseConfiguration(timeStep: Float) -> ReferenceConfiguration {
        var config = ReferenceConfiguration.default
        config.timeStep = timeStep
        config.contactStiffness = 30
        config.contactDamping = 1
        config.linearDamping = 0
        config.angularDamping = 0
        return config
    }

    private func bubble(
        _ id: Int,
        x: Float,
        velocity: Float = 0,
        radius: Float = 1
    ) throws -> ReferenceBubble {
        try ReferenceBubble(
            id: .init(rawValue: id), center: .init(x: x, y: 0),
            velocity: .init(x: velocity, y: 0), mass: 1, targetRadius: radius
        )
    }
}
