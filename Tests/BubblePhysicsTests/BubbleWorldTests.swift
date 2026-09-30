import XCTest
@testable import BubblePhysics

final class BubbleWorldTests: XCTestCase {
    func testVectorArithmeticProducesExpectedComponents() {
        let left = Vector2(x: 3, y: -2)
        let right = Vector2(x: -1, y: 5)

        XCTAssertEqual(left + right, Vector2(x: 2, y: 3))
        XCTAssertEqual(left - right, Vector2(x: 4, y: -7))
        XCTAssertEqual(left * 2, Vector2(x: 6, y: -4))
        XCTAssertEqual(left.dot(right), -13)
    }

    func testWorldAllocatesMonotonicallyIncreasingTypedBubbleIdentifiers() {
        var world = BubbleWorld(configuration: .default)

        XCTAssertEqual(world.reserveBubbleID().rawValue, 1)
        XCTAssertEqual(world.reserveBubbleID().rawValue, 2)
        XCTAssertEqual(world.reserveBubbleID().rawValue, 3)
    }

    func testWorldAppliesQueuedCommandsInFIFOOrderAtStepBoundary() {
        var world = BubbleWorld(configuration: .default)
        world.enqueue(.setGravity(Vector2(x: 0, y: -9.81)))
        world.enqueue(.setGravity(Vector2(x: 2, y: -4)))

        let report = world.step()

        XCTAssertEqual(world.gravity, Vector2(x: 2, y: -4))
        XCTAssertEqual(report.appliedCommandCount, 2)
        XCTAssertEqual(report.fixedTimeStep, WorldConfiguration.default.fixedTimeStep)
    }

    func testEquivalentWorldsProduceEquivalentReportsForSameCommandSequence() {
        var first = BubbleWorld(configuration: .default)
        var second = BubbleWorld(configuration: .default)
        let commands: [WorldCommand] = [
            .setGravity(Vector2(x: 0, y: -9.81)),
            .setGravity(Vector2(x: 3, y: -1))
        ]

        commands.forEach {
            first.enqueue($0)
            second.enqueue($0)
        }

        XCTAssertEqual(first.step(), second.step())
        XCTAssertEqual(first.gravity, second.gravity)
    }

    func testWorldReportsBroadPhaseCandidatesForOverlappingBubbleBounds() {
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 0, y: 0), restArea: .pi * 100)
        world.addBubble(center: Vector2(x: 5, y: 0), restArea: .pi * 100)

        let report = world.step()

        XCTAssertEqual(report.diagnostics.candidatePairCount, 1)
        XCTAssertEqual(report.diagnostics.contactPairCount, 1)
    }

    func testWorldStepReportsNonNegativePhaseTimings() {
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 0, y: 0), restArea: .pi * 100)

        let timings = world.step().timings

        XCTAssertGreaterThanOrEqual(timings.predictionMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timings.constraintMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timings.shapeConstraintMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timings.bubbleContactMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timings.auxiliaryConstraintMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timings.broadPhaseMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(timings.totalMilliseconds, timings.predictionMilliseconds + timings.constraintMilliseconds + timings.broadPhaseMilliseconds)
    }
}
