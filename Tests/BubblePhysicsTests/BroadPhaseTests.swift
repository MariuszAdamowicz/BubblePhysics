import XCTest
@testable import BubblePhysics

final class BroadPhaseTests: XCTestCase {
    func testMovingOneBodyUpdatesOnlyItsEndpointsAndFindsNewPair() {
        var phase = BroadPhase()
        let first = BubbleID(rawValue: 1)
        let second = BubbleID(rawValue: 2)
        phase.upsert(first, bounds: box(0, 0, 10, 10))
        phase.upsert(second, bounds: box(30, 0, 40, 10))
        XCTAssertEqual(phase.candidatePairs, [])

        phase.upsert(second, bounds: box(8, 0, 18, 10))

        XCTAssertEqual(phase.candidatePairs, [BubblePair(first, second)])
        XCTAssertEqual(phase.diagnostics.dirtyBodyCount, 1)
    }

    func testRejectsAABBsSeparatedOnEitherAxis() {
        var phase = BroadPhase()
        phase.upsert(BubbleID(rawValue: 1), bounds: box(0, 0, 10, 10))
        phase.upsert(BubbleID(rawValue: 2), bounds: box(5, 20, 15, 30))

        XCTAssertTrue(phase.candidatePairs.isEmpty)
    }

    func testLargeAndSmallOverlappingAABBsAreCandidatePair() {
        var phase = BroadPhase()
        let large = BubbleID(rawValue: 1)
        let small = BubbleID(rawValue: 2)
        phase.upsert(large, bounds: box(-100, -100, 100, 100))
        phase.upsert(small, bounds: box(90, 90, 92, 92))

        XCTAssertEqual(phase.candidatePairs, [BubblePair(large, small)])
    }

    func testRemovingBodyRemovesCandidateAndPersistentGraphRecord() {
        var phase = BroadPhase()
        let first = BubbleID(rawValue: 1)
        let second = BubbleID(rawValue: 2)
        phase.upsert(first, bounds: box(0, 0, 10, 10))
        phase.upsert(second, bounds: box(5, 0, 15, 10))
        var graph = ContactGraph()
        graph.synchronize(with: phase.candidatePairs)
        XCTAssertEqual(graph.pairs, [BubblePair(first, second)])

        phase.remove(second)
        graph.synchronize(with: phase.candidatePairs)

        XCTAssertTrue(phase.candidatePairs.isEmpty)
        XCTAssertTrue(graph.pairs.isEmpty)
    }

    func testCandidatePairsHaveStableIdentifierOrder() {
        var phase = BroadPhase()
        phase.upsert(BubbleID(rawValue: 3), bounds: box(0, 0, 10, 10))
        phase.upsert(BubbleID(rawValue: 1), bounds: box(0, 0, 10, 10))
        phase.upsert(BubbleID(rawValue: 2), bounds: box(0, 0, 10, 10))

        XCTAssertEqual(phase.candidatePairs, [
            BubblePair(BubbleID(rawValue: 1), BubbleID(rawValue: 2)),
            BubblePair(BubbleID(rawValue: 1), BubbleID(rawValue: 3)),
            BubblePair(BubbleID(rawValue: 2), BubbleID(rawValue: 3))
        ])
    }

    private func box(_ minX: Float, _ minY: Float, _ maxX: Float, _ maxY: Float) -> AABB {
        AABB(minimum: Vector2(x: minX, y: minY), maximum: Vector2(x: maxX, y: maxY))
    }
}
