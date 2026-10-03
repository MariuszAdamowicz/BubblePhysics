import XCTest
@testable import BubblePhysicsReference

final class ReferenceEquilibriumSolverTests: XCTestCase {
    func testPairContactDeformsBeforeCentersMoveFar() throws {
        var bubbles = [try bubble(1, x: 0, mass: 1), try bubble(2, x: 15, mass: 1)]
        var contacts = ReferenceContactSet(contacts: [try pairContact(bubbles[0], bubbles[1])])

        let report = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts, configuration: .default
        )

        XCTAssertFalse(bubbles[0].directionalDeformations.isEmpty)
        XCTAssertFalse(bubbles[1].directionalDeformations.isEmpty)
        XCTAssertLessThan(abs(bubbles[0].center.x), 0.1)
        XCTAssertLessThan(abs(bubbles[1].center.x - 15), 0.1)
        XCTAssertGreaterThan(report.maximumRelativeDeformation, 0)
    }

    func testLighterBubbleMovesFarther() throws {
        var bubbles = [try bubble(1, x: 0, mass: 1), try bubble(2, x: 15, mass: 3)]
        var contacts = ReferenceContactSet(contacts: [try pairContact(bubbles[0], bubbles[1])])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts, configuration: .default
        )

        XCTAssertGreaterThan(abs(bubbles[0].center.x), abs(bubbles[1].center.x - 15))
    }

    func testRigidSegmentDeformsBubbleInsteadOfProjectingItsCenterByPenetration() throws {
        var bubbles = [try bubble(1, x: 3, mass: 1)]
        let segment = verticalWall()
        let original = segment
        var contacts = ReferenceContactSet(contacts: [try segmentContact(bubbles[0], segment)])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [segment], contacts: &contacts, configuration: .default
        )

        XCTAssertEqual(segment, original)
        XCTAssertLessThan(bubbles[0].center.x, 4)
        XCTAssertGreaterThan(bubbles[0].directionalDeformations[0].depth, 6)
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
        XCTAssertFalse(bubbles[1].directionalDeformations.isEmpty)
        XCTAssertGreaterThan(bubbles[2].center.x, 30)
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

        XCTAssertFalse(bubbles[0].directionalDeformations.isEmpty)
        XCTAssertTrue(bubbles[0].directionalDeformations.allSatisfy { $0.depth.isFinite && $0.depth >= 0 })
    }

    func testNormalStressDoesNotInjectTangentialVelocityBeforeFrictionStage() throws {
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

        XCTAssertEqual(bubbles[0].velocity.x, 0)
        XCTAssertEqual(bubbles[0].angularVelocity, 0)
        XCTAssertTrue(bubbles[0].center.isFinite)
    }

    func testCorrectionCreatesAndSolvesNewCandidateContactInSameCall() throws {
        var bubbles = [
            try bubble(1, x: 0, mass: 1),
            try bubble(2, x: 15, mass: 1),
            try bubble(3, x: 36, mass: 1)
        ]
        var contacts = ReferenceContactSet(contacts: [try pairContact(bubbles[0], bubbles[1])])
        let candidates = [
            ReferencePair(.init(rawValue: 1), .init(rawValue: 2)),
            ReferencePair(.init(rawValue: 2), .init(rawValue: 3))
        ]

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts,
            configuration: .default, candidatePairs: candidates
        )

        XCTAssertFalse(bubbles[1].directionalDeformations.isEmpty)
        XCTAssertTrue(contacts.contacts.allSatisfy { $0.pressure.isFinite })
    }

    func testSymmetricWallStressDeformsWithoutMovingCenter() throws {
        var bubbles = [try bubble(1, x: 0, mass: 1)]
        let left = ReferenceSegment.staticSegment(id: .init(rawValue: 10), a: .init(x: -8, y: 20), b: .init(x: -8, y: -20))
        let right = ReferenceSegment.staticSegment(id: .init(rawValue: 11), a: .init(x: 8, y: -20), b: .init(x: 8, y: 20))
        var contacts = ReferenceContactSet(contacts: [
            try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubbles[0], left)),
            try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubbles[0], right)),
        ])
        _ = ReferenceEquilibriumSolver.solve(bubbles: &bubbles, segments: [left, right], contacts: &contacts, configuration: .default)
        XCTAssertEqual(bubbles[0].center.x, 0, accuracy: 0.01)
        XCTAssertEqual(bubbles[0].directionalDeformations.count, 2)
    }

    func testNoContactsLeavesPredictedPositionUnchanged() throws {
        var bubbles = [try bubble(1, x: 7, mass: 1)]
        var contacts = ReferenceContactSet()
        let report = ReferenceEquilibriumSolver.solve(bubbles: &bubbles, segments: [], contacts: &contacts, configuration: .default)
        XCTAssertEqual(bubbles[0].center.x, 7)
        XCTAssertEqual(report.finalResidualNorm, 0)
    }

    func testAlmostFullCompressionAndCoincidentCentersRemainFiniteAndDeterministic() throws {
        var first = [try bubble(1, x: 0, mass: 1), try bubble(2, x: 0, mass: 1)]
        var second = first
        var contactsA = ReferenceContactSet(contacts: [try pairContact(first[0], first[1])])
        var contactsB = contactsA
        let reportA = ReferenceEquilibriumSolver.solve(bubbles: &first, segments: [], contacts: &contactsA, configuration: .default)
        let reportB = ReferenceEquilibriumSolver.solve(bubbles: &second, segments: [], contacts: &contactsB, configuration: .default)
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { $0.center.isFinite && $0.directionalDeformations.allSatisfy { $0.depth.isFinite } })
        XCTAssertFalse(reportA.hasNonFiniteState)
        XCTAssertEqual(reportA, reportB)
    }

    func testActiveSetLineSearchDoesNotIncreaseTotalPairEnergy() throws {
        var configuration = ReferenceConfiguration.default
        configuration.timeStep = 1
        var bubbles = [
            try ReferenceBubble(id: .init(rawValue: 1), center: .init(x: 0, y: 0), mass: 1, targetRadius: 10, stiffness: 1),
            try ReferenceBubble(id: .init(rawValue: 2), center: .init(x: 15, y: 0), mass: 1, targetRadius: 10, stiffness: 100_000_000),
            try ReferenceBubble(id: .init(rawValue: 3), center: .init(x: 35.0001, y: 0), mass: 100, targetRadius: 10, stiffness: 100_000_000),
        ]
        let initial = totalPairEnergy(bubbles, alpha: configuration.nonlinearStiffening)
        var contacts = ReferenceContactSet(contacts: [try pairContact(bubbles[0], bubbles[1])])
        let candidates = [
            ReferencePair(.init(rawValue: 1), .init(rawValue: 2)),
            ReferencePair(.init(rawValue: 2), .init(rawValue: 3)),
        ]

        _ = ReferenceEquilibriumSolver.solve(bubbles: &bubbles, segments: [], contacts: &contacts,
                                             configuration: configuration, candidatePairs: candidates)

        XCTAssertLessThanOrEqual(totalPairEnergy(bubbles, alpha: configuration.nonlinearStiffening), initial + 0.001)
    }

    private func totalPairEnergy(_ bubbles: [ReferenceBubble], alpha: Float) -> Float {
        var total: Float = 0
        for a in bubbles.indices {
            for b in bubbles.indices where b > a {
                let depth = max(0, bubbles[a].targetRadius + bubbles[b].targetRadius
                                - (bubbles[b].center - bubbles[a].center).length)
                let stress = ReferenceDeformationLaw.solve(requiredCompression: depth,
                    radiusA: bubbles[a].targetRadius, stiffnessA: bubbles[a].stiffness,
                    radiusB: bubbles[b].targetRadius, stiffnessB: bubbles[b].stiffness,
                    nonlinearStiffening: alpha)
                for (d, bubble) in [(stress.compressionA, bubbles[a]), (stress.compressionB, bubbles[b])] {
                    let d2 = d * d
                    total += 0.5 * bubble.stiffness * d2
                        + 0.25 * bubble.stiffness * alpha * d2 * d2 / (bubble.targetRadius * bubble.targetRadius)
                }
            }
        }
        return total
    }

    func testKinematicVelocityUsesUnitsPerSecond() {
        let segment = ReferenceSegment.kinematicSegment(
            id: .init(rawValue: 9),
            previousA: .init(x: 0, y: 0), previousB: .init(x: 10, y: 0),
            currentA: .init(x: 1, y: 0), currentB: .init(x: 11, y: 0),
            timeStep: 0.5
        )
        XCTAssertEqual(segment.linearVelocity.x, 2, accuracy: 0.0001)
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
        var oneSidedSegment = segment
        oneSidedSegment.collisionMode = .oneSided(allowedSide: allowedSide)
        return try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, oneSidedSegment))
    }
}
