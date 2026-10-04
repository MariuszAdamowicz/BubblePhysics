import XCTest
@testable import BubblePhysicsReference

final class ReferenceEquilibriumSolverTests: XCTestCase {
    func testDefaultConfigurationPreservesFourIterationBehavior() {
        XCTAssertEqual(ReferenceConfiguration.default.solverIterations, 4)
    }

    func testSolverHonorsConfiguredNewtonLimitAboveFour() throws {
        var config = configuration()
        config.solverIterations = 8
        config.pcgIterationLimit = 1
        config.stressTolerance = Float.leastNonzeroMagnitude
        config.contactStiffness = 800
        config.nonlinearStiffening = 20

        var bubbles = [
            try bubble(1, x: 4, y: -3),
            try bubble(2, x: 17, y: 2),
            try bubble(3, x: 30, y: -2),
        ]
        let wall = verticalWall(x: 0)
        var contacts = ReferenceContactSet(contacts: [
            try contact(bubbles[0], wall),
            try pair(bubbles[0], bubbles[1]),
            try pair(bubbles[1], bubbles[2]),
        ])

        let report = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles,
            segments: [wall],
            contacts: &contacts,
            configuration: config,
            timeStep: 0.2
        )

        XCTAssertGreaterThan(report.iterations, 4)
        XCTAssertLessThanOrEqual(report.iterations, 8)
    }

    func testUnbalancedContactChangesVelocityInForceDirection() throws {
        var bubbles = [try bubble(1, x: 8)]
        let wall = verticalWall(x: 0)
        var contacts = ReferenceContactSet(contacts: [try contact(bubbles[0], wall)])
        let report = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [wall], contacts: &contacts,
            configuration: configuration(), timeStep: 0.1
        )
        XCTAssertGreaterThan(bubbles[0].velocity.x, 0)
        XCTAssertGreaterThan(bubbles[0].center.x, 8)
        XCTAssertLessThan(report.finalResidualNorm, report.initialResidualNorm)
    }

    func testContactResponseTimeDoesNotSlowDownForHeavierBubble() throws {
        let wall = verticalWall(x: 0)
        var light = [try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 8, y: 0), velocity: .zero,
            mass: 2, targetRadius: 10
        )]
        var heavy = [try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 8, y: 0), velocity: .zero,
            mass: 200, targetRadius: 10
        )]
        var lightContacts = ReferenceContactSet(contacts: [try contact(light[0], wall)])
        var heavyContacts = ReferenceContactSet(contacts: [try contact(heavy[0], wall)])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &light, segments: [wall], contacts: &lightContacts,
            configuration: configuration(), timeStep: 0.1
        )
        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &heavy, segments: [wall], contacts: &heavyContacts,
            configuration: configuration(), timeStep: 0.1
        )

        XCTAssertEqual(heavy[0].center.x, light[0].center.x, accuracy: 1e-4)
        XCTAssertEqual(heavy[0].velocity.x, light[0].velocity.x, accuracy: 1e-3)
    }

    func testBalancedContactsDoNotMoveCenter() throws {
        var bubbles = [try bubble(1, x: 0)]
        let left = verticalWall(x: -8)
        let right = verticalWall(id: 2, x: 8)
        var contacts = ReferenceContactSet(contacts: [try contact(bubbles[0], left), try contact(bubbles[0], right)])
        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [left, right], contacts: &contacts,
            configuration: configuration(), timeStep: 0.1
        )
        XCTAssertEqual(bubbles[0].center.x, 0, accuracy: 1e-5)
        XCTAssertEqual(bubbles[0].velocity.x, 0, accuracy: 1e-5)
    }

    func testThreeBubbleChainTransfersReactionWithinOneSolve() throws {
        var bubbles = [try bubble(1, x: 0), try bubble(2, x: 18), try bubble(3, x: 36)]
        var contacts = ReferenceContactSet(contacts: [try pair(bubbles[0], bubbles[1]), try pair(bubbles[1], bubbles[2])])
        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts,
            configuration: configuration(), timeStep: 0.1
        )
        XCTAssertLessThan(bubbles[0].velocity.x, 0)
        XCTAssertGreaterThan(bubbles[2].velocity.x, 0)
        XCTAssertEqual(bubbles[1].velocity.x, 0, accuracy: 5e-4)
    }

    func testSolvedPairContactUpdatesSharedContourPlane() throws {
        var bubbles = [try bubble(1, x: 0), try bubble(2, x: 18)]
        var contacts = ReferenceContactSet(contacts: [try pair(bubbles[0], bubbles[1])])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts,
            configuration: configuration(), timeStep: 0.1
        )

        let contact = try XCTUnwrap(contacts.contacts.first)
        let expectedMidpoint = (bubbles[0].center + bubbles[1].center) * 0.5
        XCTAssertEqual(contact.pointQ.x, expectedMidpoint.x, accuracy: 1e-4)
        XCTAssertEqual(contact.pointQ.y, expectedMidpoint.y, accuracy: 1e-4)
    }

    func testContainedSmallBubbleStillProducesFiniteSharedContourChord() throws {
        var bubbles = [
            try ReferenceBubble(
                id: .init(rawValue: 1), center: .zero, velocity: .zero,
                mass: 1_000, targetRadius: 10
            ),
            try ReferenceBubble(
                id: .init(rawValue: 2), center: .init(x: 5, y: 0), velocity: .zero,
                mass: 1_000, targetRadius: 3
            ),
        ]
        var contacts = ReferenceContactSet(contacts: [try pair(bubbles[0], bubbles[1])])

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts,
            configuration: configuration(), timeStep: 1 / 60
        )

        let contact = try XCTUnwrap(contacts.contacts.first)
        XCTAssertGreaterThan(try XCTUnwrap(contact.contourHalfLength), 0.1)
        XCTAssertGreaterThan(contact.pointQ.x, bubbles[1].center.x)
        XCTAssertLessThan(contact.pointQ.x, bubbles[0].center.x + bubbles[0].targetRadius)
    }

    func testOneFullStepIsCloseToTwoHalfSteps() throws {
        let wall = verticalWall(x: 0)
        var full = [try bubble(1, x: 8)]
        var fullContacts = ReferenceContactSet(contacts: [try contact(full[0], wall)])
        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &full, segments: [wall], contacts: &fullContacts,
            configuration: configuration(), timeStep: 0.1
        )
        var halves = [try bubble(1, x: 8)]
        var halfContacts = ReferenceContactSet(contacts: [try contact(halves[0], wall)])
        for _ in 0..<2 {
            _ = ReferenceEquilibriumSolver.solve(
                bubbles: &halves, segments: [wall], contacts: &halfContacts,
                configuration: configuration(), timeStep: 0.05
            )
        }
        XCTAssertEqual(full[0].center.x, halves[0].center.x, accuracy: 0.08)
        XCTAssertEqual(full[0].velocity.x, halves[0].velocity.x, accuracy: 0.35)
    }

    func testNewtonLimitReturnsFiniteStateAndReportsLimit() throws {
        var config = configuration()
        config.solverIterations = 1
        config.stressTolerance = 1e-12
        var bubbles = [try bubble(1, x: 7, y: 1)]
        let wall = verticalWall(x: 0)
        var contacts = ReferenceContactSet(contacts: [try contact(bubbles[0], wall)])
        let report = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [wall], contacts: &contacts,
            configuration: config, timeStep: 0.2
        )
        XCTAssertTrue(report.didReachNewtonLimit)
        XCTAssertTrue(bubbles[0].center.isFinite)
        XCTAssertTrue(bubbles[0].velocity.isFinite)
        XCTAssertFalse(report.hasNonFiniteState)
    }

    func testNoContactsPreserveFreeMotion() throws {
        var bubbles = [try bubble(1, x: 3, velocity: .init(x: 4, y: -2))]
        var contacts = ReferenceContactSet()
        let report = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts,
            configuration: configuration(), timeStep: 0.25
        )
        XCTAssertEqual(bubbles[0].center.x, 4, accuracy: 1e-5)
        XCTAssertEqual(bubbles[0].center.y, -0.5, accuracy: 1e-5)
        XCTAssertEqual(bubbles[0].velocity.x, 4, accuracy: 1e-5)
        XCTAssertEqual(bubbles[0].velocity.y, -2, accuracy: 1e-5)
        XCTAssertTrue(report.converged)
    }

    func testMassNormalizedDragSlowsFreeHeavyBubble() throws {
        var config = configuration()
        config.linearDamping = 0.8
        var bubbles = [try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero,
            velocity: .init(x: 20, y: 0), mass: 200, targetRadius: 10
        )]
        var contacts = ReferenceContactSet()

        _ = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles, segments: [], contacts: &contacts,
            configuration: config, timeStep: 1 / 60
        )

        XCTAssertLessThan(bubbles[0].velocity.x, 20)
        XCTAssertGreaterThan(bubbles[0].velocity.x, 19)
    }

    private func configuration() -> ReferenceConfiguration {
        var value = ReferenceConfiguration.default
        value.contactStiffness = 10
        value.contactDamping = 0
        value.linearDamping = 0
        value.solverIterations = 4
        value.pcgIterationLimit = 16
        value.stressTolerance = 1e-5
        value.pcgTolerance = 1e-6
        return value
    }

    private func bubble(
        _ id: Int, x: Float, y: Float = 0, velocity: ReferenceVector2 = .zero
    ) throws -> ReferenceBubble {
        try ReferenceBubble(
            id: .init(rawValue: id), center: .init(x: x, y: y), velocity: velocity,
            mass: 2, targetRadius: 10
        )
    }

    private func verticalWall(id: Int = 1, x: Float) -> ReferenceSegment {
        .staticSegment(id: .init(rawValue: id), a: .init(x: x, y: -100), b: .init(x: x, y: 100))
    }

    private func contact(_ bubble: ReferenceBubble, _ segment: ReferenceSegment) throws -> ReferenceContact {
        try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment))
    }

    private func pair(_ a: ReferenceBubble, _ b: ReferenceBubble) throws -> ReferenceContact {
        try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleBubble(a, b))
    }
}
