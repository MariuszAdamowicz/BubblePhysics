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

    func testKinematicSegmentTransfersMotion() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 0, y: 1), mass: 1, targetRadius: 2
        ))
        world.addSegment(.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .init(x: -5, y: 0), previousB: .init(x: 5, y: 0),
            currentA: .init(x: -1, y: 0), currentB: .init(x: 9, y: 0)
        ), allowedSide: 1)

        _ = world.step()

        XCTAssertGreaterThan(world.bubbles[0].velocity.x, 0)
        XCTAssertGreaterThan(world.bubbles[0].angularVelocity, 0)
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
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: -5, y: -5), b: .init(x: -5, y: 5)), allowedSide: -1)
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 5, y: -5), b: .init(x: 5, y: 5)), allowedSide: 1)
        world.addSegment(.staticSegment(id: .init(rawValue: 3), a: .init(x: -5, y: -5), b: .init(x: 5, y: -5)), allowedSide: 1)
        world.addSegment(.staticSegment(id: .init(rawValue: 4), a: .init(x: -5, y: 5), b: .init(x: 5, y: 5)), allowedSide: -1)

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
            angularVelocity: .pi * 0.5
        ), allowedSide: 1)

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

    private func makeChainWorld() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .default, broadPhase: SweepAndPruneBroadPhase())
        world.addBubble(try ReferenceBubble(id: .init(rawValue: 1), center: .init(x: 0, y: 0), velocity: .init(x: 2, y: 0), mass: 1, targetRadius: 10))
        world.addBubble(try ReferenceBubble(id: .init(rawValue: 2), center: .init(x: 15, y: 0), mass: 1, targetRadius: 10))
        world.addBubble(try ReferenceBubble(id: .init(rawValue: 3), center: .init(x: 30, y: 0), mass: 1, targetRadius: 10))
        return world
    }
}
