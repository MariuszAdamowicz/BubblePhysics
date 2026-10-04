import XCTest
@testable import BubblePhysicsReference

final class ReferenceWorldTests: XCTestCase {
    func testDeeplyOverlappingUnequalBubblesSeparateInsteadOfContainingOneAnother() throws {
        var configuration = ReferenceConfiguration.default
        configuration.linearDamping = 0.8
        var world = ReferenceWorld(
            configuration: configuration, broadPhase: SweepAndPruneBroadPhase()
        )
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero, mass: 18, targetRadius: 30
        ))
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 2), center: .init(x: 8, y: 0), mass: 4, targetRadius: 10
        ))

        for _ in 0..<120 { _ = world.step() }

        let distance = (world.bubbles[1].center - world.bubbles[0].center).length
        XCTAssertGreaterThan(distance, 39)
        XCTAssertFalse(world.bubbles.contains { !$0.center.isFinite || !$0.velocity.isFinite })
    }

    func testSmallerBubbleAbsorbsMoreOfPairDeformation() throws {
        var configuration = ReferenceConfiguration.default
        configuration.linearDamping = 0
        var world = ReferenceWorld(
            configuration: configuration, broadPhase: SweepAndPruneBroadPhase()
        )
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero, mass: 10_000, targetRadius: 10
        ))
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 2), center: .init(x: 35, y: 0),
            mass: 10_000, targetRadius: 30
        ))

        _ = world.step()

        let contact = try XCTUnwrap(world.contacts.contacts.first)
        XCTAssertGreaterThan(contact.compressionA, contact.compressionB)
        XCTAssertEqual(
            contact.compressionA + contact.compressionB,
            contact.penetration,
            accuracy: 0.001
        )
    }

    func testMoreCompliantBubbleAbsorbsMoreOfPairDeformation() throws {
        var world = ReferenceWorld(
            configuration: .default, broadPhase: SweepAndPruneBroadPhase()
        )
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero, mass: 10_000,
            targetRadius: 20, stiffness: 0.5
        ))
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 2), center: .init(x: 35, y: 0), mass: 10_000,
            targetRadius: 20, stiffness: 2
        ))

        _ = world.step()

        let contact = try XCTUnwrap(world.contacts.contacts.first)
        XCTAssertGreaterThan(contact.compressionA, contact.compressionB)
    }

    func testBubbleCenterCannotRemainInsideClosedPolygon() throws {
        var world = ReferenceWorld(
            configuration: .default, broadPhase: SweepAndPruneBroadPhase()
        )
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 2
        ))
        let vertices = [
            ReferenceVector2(x: -10, y: 8),
            ReferenceVector2(x: 10, y: 8),
            ReferenceVector2(x: 0, y: -10),
        ]
        for index in vertices.indices {
            world.addSegment(.staticSegment(
                id: .init(rawValue: index + 1),
                a: vertices[index], b: vertices[(index + 1) % vertices.count],
                ownerID: 100, collisionMode: .twoSided
            ))
        }

        let report = world.step()

        XCTAssertFalse(pointInPolygon(world.bubbles[0].center, vertices))
        XCTAssertGreaterThan(report.centerGuardCount, 0)
        XCTAssertTrue(world.bubbles[0].center.isFinite)
    }

    func testStationaryContactIsRemovedAfterSegmentMovesAway() throws {
        var world = ReferenceWorld(
            configuration: .default, broadPhase: SweepAndPruneBroadPhase()
        )
        let id = ReferenceBubbleID(rawValue: 1)
        world.addBubble(try ReferenceBubble(
            id: id, center: .zero, mass: 1, targetRadius: 10
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 1), a: .init(x: 5, y: -20), b: .init(x: 5, y: 20),
            collisionMode: .twoSided
        ))
        _ = world.step()
        XCTAssertFalse(world.contacts.contacts.isEmpty)

        var restingBubble = world.bubbles[0]
        restingBubble.velocity = .zero
        world.updateBubble(restingBubble)
        world.updateSegment(.staticSegment(
            id: .init(rawValue: 1), a: .init(x: 100, y: -20), b: .init(x: 100, y: 20),
            collisionMode: .twoSided
        ))
        _ = world.step()

        XCTAssertTrue(world.contacts.contacts.isEmpty)
        let radii = world.contour(for: id).map { ($0 - world.bubbles[0].center).length }
        XCTAssertTrue(radii.allSatisfy { abs($0 - 10) < 0.01 })
    }

    func testBubbleDeeplyCompressedByTwoSidedPolygonEdgeIsEjected() throws {
        var configuration = ReferenceConfiguration.default
        configuration.timeStep = 1 / 60
        configuration.contactStiffness = 300
        configuration.contactDamping = 26
        configuration.linearDamping = 0.8
        var world = ReferenceWorld(
            configuration: configuration, broadPhase: SweepAndPruneBroadPhase()
        )
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 0, y: 5), mass: 200,
            targetRadius: 10
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 1), a: .init(x: -20, y: 0), b: .init(x: 20, y: 0),
            ownerID: 100, collisionMode: .twoSided
        ))

        for _ in 0..<120 { _ = world.step() }

        XCTAssertGreaterThan(world.bubbles[0].center.y, 9.9)
        XCTAssertTrue(world.contacts.contacts.isEmpty)
    }

    func testBubbleCompressedAgainstWallAcceleratesBackIntoChamber() throws {
        var configuration = ReferenceConfiguration.default
        configuration.timeStep = 1 / 60
        var world = ReferenceWorld(configuration: configuration, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 2, y: 50), mass: 1,
            targetRadius: 20
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 0, y: 100),
            collisionMode: .oneSided(allowedSide: -1)
        ))

        var report = world.step()
        for _ in 0..<29 { report = world.step() }

        XCTAssertGreaterThan(world.bubbles[0].center.x, 2)
        XCTAssertGreaterThan(world.bubbles[0].velocity.x, 0)
        XCTAssertEqual(report.centerGuardCount, 0)
        XCTAssertFalse(report.hasNonFiniteState)
    }

    func testOpposingWallsDriveCenterTowardMidplane() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 1, y: 50), mass: 1,
            targetRadius: 20
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 0, y: 100),
            collisionMode: .oneSided(allowedSide: -1)
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 2), a: .init(x: 10, y: 100), b: .init(x: 10, y: 0),
            collisionMode: .oneSided(allowedSide: -1)
        ))

        for _ in 0..<60 { _ = world.step() }

        XCTAssertEqual(world.bubbles[0].center.x, 5, accuracy: 0.75)
        XCTAssertFalse(world.bubbles[0].velocity.x.isNaN)
    }
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
        // Pair contacts use the reduced mass (0.5 here), so these per-unit-mass
        // coefficients preserve the response used by this event-topology fixture.
        config.contactStiffness = 60
        config.contactDamping = 2
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

    private func pointInPolygon(
        _ point: ReferenceVector2, _ vertices: [ReferenceVector2]
    ) -> Bool {
        var inside = false
        for index in vertices.indices {
            let a = vertices[index]
            let b = vertices[(index + 1) % vertices.count]
            if (a.y > point.y) != (b.y > point.y) {
                let crossingX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x
                if point.x < crossingX { inside.toggle() }
            }
        }
        return inside
    }
}
