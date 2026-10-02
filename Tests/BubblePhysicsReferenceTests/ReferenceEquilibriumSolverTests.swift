import XCTest
@testable import BubblePhysicsReference

final class ReferenceEquilibriumSolverTests: XCTestCase {
    func testEqualMassesSplitPositionalCorrectionSymmetrically() throws {
        var bubbles = [try bubble(1, x: 0, mass: 1), try bubble(2, x: 15, mass: 1)]
        var contacts = ReferenceContactSet(contacts: [try pairContact(bubbles[0], bubbles[1])])

        let report = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts, configuration: .default
        )

        XCTAssertEqual(bubbles[0].center.x, -2.5, accuracy: 0.01)
        XCTAssertEqual(bubbles[1].center.x, 17.5, accuracy: 0.01)
        XCTAssertLessThanOrEqual(report.maximumPenetration, ReferenceConfiguration.default.positionTolerance)
    }

    func testLighterBubbleMovesFarther() throws {
        var bubbles = [try bubble(1, x: 0, mass: 1), try bubble(2, x: 15, mass: 3)]
        var contacts = ReferenceContactSet(contacts: [try pairContact(bubbles[0], bubbles[1])])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts, configuration: .default
        )

        XCTAssertEqual(abs(bubbles[0].center.x), 3.75, accuracy: 0.01)
        XCTAssertEqual(bubbles[1].center.x - 15, 1.25, accuracy: 0.01)
    }

    func testRigidSegmentNeverMovesWhileBubbleIsProjectedOut() throws {
        var bubbles = [try bubble(1, x: 3, mass: 1)]
        let segment = verticalWall()
        let original = segment
        var contacts = ReferenceContactSet(contacts: [try segmentContact(bubbles[0], segment)])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [segment], contacts: &contacts, configuration: .default
        )

        XCTAssertEqual(segment, original)
        XCTAssertGreaterThanOrEqual(bubbles[0].center.x, 9.999)
    }

    func testChainPropagatesCorrectionAcrossThreeBubbles() throws {
        var bubbles = [try bubble(1, x: 0, mass: 1), try bubble(2, x: 15, mass: 1), try bubble(3, x: 30, mass: 1)]
        var contacts = ReferenceContactSet(contacts: [
            try pairContact(bubbles[0], bubbles[1]),
            try pairContact(bubbles[1], bubbles[2])
        ])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts, configuration: .default
        )

        XCTAssertLessThan(bubbles[0].center.x, 0)
        XCTAssertGreaterThan(bubbles[2].center.x, 30)
        XCTAssertGreaterThanOrEqual(bubbles[1].center.x - bubbles[0].center.x, 19.9)
        XCTAssertGreaterThanOrEqual(bubbles[2].center.x - bubbles[1].center.x, 19.9)
    }

    func testWallBlockedCorrectionBecomesDirectionalDeformation() throws {
        var bubbles = [try bubble(1, x: 9, mass: 1), try bubble(2, x: 18, mass: 1)]
        let wall = verticalWall()
        var contacts = ReferenceContactSet(contacts: [
            try pairContact(bubbles[0], bubbles[1]),
            try segmentContact(bubbles[0], wall)
        ])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [wall], contacts: &contacts, configuration: .default
        )

        XCTAssertGreaterThanOrEqual(bubbles[0].center.x, 9.999)
        XCTAssertFalse(bubbles[0].directionalDeformations.isEmpty)
        XCTAssertTrue(bubbles[0].directionalDeformations.allSatisfy { $0.depth.isFinite && $0.depth >= 0 })
    }

    func testMovingSegmentTransfersBoundedTangentialVelocityAndRotation() throws {
        var bubbles = [try ReferenceBubble(id: .init(rawValue: 1), center: .init(x: 0, y: 1), mass: 1, targetRadius: 2)]
        let segment = ReferenceSegment.kinematicSegment(
            id: .init(rawValue: 1),
            previousA: .init(x: -5, y: 0), previousB: .init(x: 5, y: 0),
            currentA: .init(x: -1, y: 0), currentB: .init(x: 9, y: 0)
        )
        var contacts = ReferenceContactSet(contacts: [try segmentContact(bubbles[0], segment, allowedSide: 1)])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [segment], contacts: &contacts, configuration: .default
        )

        XCTAssertGreaterThan(bubbles[0].velocity.x, 0)
        XCTAssertLessThanOrEqual(bubbles[0].velocity.x, segment.linearVelocity.x)
        XCTAssertGreaterThan(bubbles[0].angularVelocity, 0)
        XCTAssertTrue(bubbles[0].center.isFinite)
    }

    private func bubble(_ id: Int, x: Float, mass: Float) throws -> ReferenceBubble {
        try ReferenceBubble(id: .init(rawValue: id), center: .init(x: x, y: 0), mass: mass, targetRadius: 10)
    }

    private func verticalWall() -> ReferenceSegment {
        .staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -100), b: .init(x: 0, y: 100))
    }

    private func pairContact(_ a: ReferenceBubble, _ b: ReferenceBubble) throws -> ReferenceContact {
        try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleBubble(a, b))
    }

    private func segmentContact(
        _ bubble: ReferenceBubble,
        _ segment: ReferenceSegment,
        allowedSide: Float = -1
    ) throws -> ReferenceContact {
        try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment, allowedSide: allowedSide))
    }
}
