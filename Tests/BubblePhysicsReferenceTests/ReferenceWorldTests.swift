import XCTest
@testable import BubblePhysicsReference

final class ReferenceWorldTests: XCTestCase {
    func testSixHundredStepsAreDeterministic() throws {
        var first = try makeChainWorld()
        var second = try makeChainWorld()

        for _ in 0..<600 {
            _ = first.step()
            _ = second.step()
        }

        XCTAssertEqual(first.bubbles, second.bubbles)
        XCTAssertEqual(first.contacts, second.contacts)
    }

    func testFreeMotionIsDamped() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero,
            velocity: .init(x: 60, y: 0), mass: 1, targetRadius: 2
        ))

        _ = world.step()

        XCTAssertGreaterThan(world.bubbles[0].center.x, 0)
        XCTAssertGreaterThan(world.bubbles[0].velocity.x, 0)
        XCTAssertLessThan(world.bubbles[0].velocity.x, 60)
    }

    func testKinematicSegmentTransfersBoundedMotionWithFriction() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 0, y: 1), mass: 1, targetRadius: 2
        ))
        world.addSegment(.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .init(x: -5, y: 0), previousB: .init(x: 5, y: 0),
            currentA: .init(x: -1, y: 0), currentB: .init(x: 9, y: 0),
            collisionMode: .oneSided(allowedSide: 1)
        ))

        _ = world.step()

        XCTAssertGreaterThan(world.bubbles[0].velocity.x, 0)
        XCTAssertLessThanOrEqual(world.bubbles[0].velocity.x, world.segments[0].linearVelocity.x)
        XCTAssertTrue(world.bubbles[0].angularVelocity.isFinite)
    }

    func testZeroFrictionDoesNotChangeAngularVelocity() throws {
        var configuration = ReferenceConfiguration.default
        configuration.surfaceFriction = 0
        var world = ReferenceWorld(configuration: configuration, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 0, y: 1), mass: 1, targetRadius: 2
        ))
        world.addSegment(.kinematicSegment(
            id: .init(rawValue: 1), previousA: .init(x: -5, y: 0), previousB: .init(x: 5, y: 0),
            currentA: .init(x: -1, y: 0), currentB: .init(x: 9, y: 0), collisionMode: .oneSided(allowedSide: 1)
        ))
        _ = world.step()
        XCTAssertEqual(world.bubbles[0].angularVelocity, 0)
    }

    func testContactsDoNotGrowWithoutBound() throws {
        var world = try makeChainWorld()
        var peak = 0
        for _ in 0..<300 {
            let report = world.step()
            peak = max(peak, report.persistentContactCount)
        }
        XCTAssertLessThanOrEqual(peak, 2)
    }

    func testBubbleLargerThanBoardCompressesAndStopsWithinIterationBudget() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 20
        ))
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: -5, y: -5), b: .init(x: -5, y: 5), collisionMode: .oneSided(allowedSide: -1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 5, y: -5), b: .init(x: 5, y: 5), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 3), a: .init(x: -5, y: -5), b: .init(x: 5, y: -5), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 4), a: .init(x: -5, y: 5), b: .init(x: 5, y: 5), collisionMode: .oneSided(allowedSide: -1)))

        let report = world.step()

        XCTAssertTrue(world.bubbles[0].center.isFinite)
        XCTAssertGreaterThanOrEqual(world.bubbles[0].directionalDeformations.count, 4)
        XCTAssertLessThanOrEqual(report.solver.iterations, ReferenceConfiguration.default.solverIterations)
        XCTAssertFalse(report.hasNonFiniteState)
    }

    func testFastRotatingSegmentCannotMoveBubbleToForbiddenSide() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 0, y: 3), mass: 1, targetRadius: 1
        ))
        world.addSegment(.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .init(x: -5, y: 0), previousB: .init(x: 5, y: 0),
            currentA: .init(x: 0, y: 5), currentB: .init(x: 0, y: -5),
            angularVelocity: .pi * 0.5,
            collisionMode: .oneSided(allowedSide: 1)
        ))

        let report = world.step()
        let segment = world.segments[0]
        let allowedNormal = ReferenceVector2(x: -(segment.currentB - segment.currentA).y, y: (segment.currentB - segment.currentA).x)
        XCTAssertGreaterThanOrEqual((world.bubbles[0].center - segment.currentA).dot(allowedNormal), 0)
        XCTAssertGreaterThan(report.toiTestCount, 0)
    }

    func testContourIsGeneratedOnlyOnRequestFromSolvedState() throws {
        var world = try makeChainWorld()
        let report = world.step()
        XCTAssertEqual(report.generatedContourPointCount, 0)
        let contour = world.contour(for: .init(rawValue: 1))
        XCTAssertFalse(contour.isEmpty)
    }

    func testInactiveDeformationRecoversTowardTargetRadius() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try bubbleForRecovery(id: 1, x: 9))
        world.addBubble(try bubbleForRecovery(id: 2, x: 18))
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -100), b: .init(x: 0, y: 100), collisionMode: .oneSided(allowedSide: -1)))
        _ = world.step()
        let compressed = world.bubbles[0].directionalDeformations.map(\.depth).max() ?? 0
        XCTAssertGreaterThan(compressed, 0)

        world.removeSegment(id: .init(rawValue: 1))
        world.updateBubble(try ReferenceBubble(
            id: .init(rawValue: 2), center: .init(x: 80, y: 0), mass: 1, targetRadius: 10
        ))
        for _ in 0..<30 { _ = world.step() }
        let recovered = world.bubbles[0].directionalDeformations.map(\.depth).max() ?? 0
        XCTAssertLessThan(recovered, compressed * 0.1)
    }

    func testInvalidConfigurationIsSanitizedAtWorldBoundary() throws {
        var invalid = ReferenceConfiguration.default
        invalid.timeStep = 0
        invalid.solverIterations = -4
        invalid.toiIterationBudget = -2
        invalid.maxContourSegmentLength = 0
        var world = ReferenceWorld(configuration: invalid, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try bubbleForRecovery(id: 1, x: 0))
        let report = world.step()
        XCTAssertFalse(report.hasNonFiniteState)
        XCTAssertFalse(world.contour(for: .init(rawValue: 1)).isEmpty)
    }

    func testWorldPreservesContactHysteresisOutsideBroadPhaseOverlap() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try bubbleForRecovery(id: 1, x: 0))
        world.addBubble(try bubbleForRecovery(id: 2, x: 19.998))
        _ = world.step()
        XCTAssertEqual(world.contacts.contacts.count, 1)
        world.updateBubble(try bubbleForRecovery(id: 1, x: 0))
        world.updateBubble(try bubbleForRecovery(id: 2, x: 20.001))

        _ = world.step()

        let retained = try XCTUnwrap(world.contacts.contacts.first)
        XCTAssertLessThan(retained.penetration, 0)
    }

    func testWorldReportsExhaustedCCDBudget() throws {
        var configuration = ReferenceConfiguration.default
        configuration.toiIterationBudget = 1
        var world = ReferenceWorld(configuration: configuration, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 2, y: 2), mass: 1, targetRadius: 0.5
        ))
        world.addSegment(.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .zero, previousB: .init(x: 4, y: 0),
            currentA: .zero, currentB: .init(x: 0, y: 4),
            collisionMode: .oneSided(allowedSide: 1)
        ))

        let report = world.step()

        XCTAssertEqual(report.ccdBudgetExhaustionCount, 1)
    }

    func testSmallElasticStepDoesNotInventDistantContact() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try bubbleForRecovery(id: 1, x: 0))
        world.addBubble(try bubbleForRecovery(id: 2, x: 15))
        world.addBubble(try bubbleForRecovery(id: 3, x: 36))

        let report = world.step()

        XCTAssertEqual(report.candidatePairCount, 1)
        XCTAssertGreaterThanOrEqual(world.bubbles[2].center.x - world.bubbles[1].center.x, 19.9)
        XCTAssertFalse(world.contacts.contacts.contains {
            $0.bubbleA == .init(rawValue: 2) && $0.bubbleB == .init(rawValue: 3)
        })
    }

    func testGeneratedContactCountExcludesDistantSignedSegmentCandidates() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 100, y: 100), mass: 1, targetRadius: 2
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 1), a: .init(x: 0, y: -10), b: .init(x: 0, y: 10),
            collisionMode: .oneSided(allowedSide: -1)
        ))

        let report = world.step()

        XCTAssertEqual(report.generatedContactCount, 0)
        XCTAssertEqual(report.persistentContactCount, 0)
    }

    private func bubbleForRecovery(id: Int, x: Float) throws -> ReferenceBubble {
        try ReferenceBubble(id: .init(rawValue: id), center: .init(x: x, y: 0), mass: 1, targetRadius: 10)
    }

    private func makeChainWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(id: .init(rawValue: 1), center: .init(x: 0, y: 0), velocity: .init(x: 2, y: 0), mass: 1, targetRadius: 10))
        world.addBubble(try ReferenceBubble(id: .init(rawValue: 2), center: .init(x: 15, y: 0), mass: 1, targetRadius: 10))
        world.addBubble(try ReferenceBubble(id: .init(rawValue: 3), center: .init(x: 30, y: 0), mass: 1, targetRadius: 10))
        return world
    }
}
