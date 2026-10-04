import XCTest
@testable import BubblePhysicsReference

final class ReferenceModelTests: XCTestCase {
    func testBubbleRejectsNonPositiveMassAndRadius() {
        XCTAssertThrowsError(
            try ReferenceBubble(id: .init(rawValue: 1), center: .zero, mass: 0, targetRadius: 10)
        )
        XCTAssertThrowsError(
            try ReferenceBubble(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 0)
        )
    }

    func testStaticSegmentKeepsPreviousAndCurrentEndpoints() {
        let a = ReferenceVector2(x: 10, y: 20)
        let b = ReferenceVector2(x: 30, y: 40)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 2),
            a: a,
            b: b
        )

        XCTAssertEqual(segment.previousA, a)
        XCTAssertEqual(segment.previousB, b)
        XCTAssertEqual(segment.currentA, a)
        XCTAssertEqual(segment.currentB, b)
        XCTAssertEqual(segment.linearVelocity, .zero)
        XCTAssertEqual(segment.angularVelocity, 0)
        XCTAssertEqual(segment.motion, .staticBody)
    }

    func testDefaultConfigurationHasFinitePositiveBudgets() {
        let configuration = ReferenceConfiguration.default

        XCTAssertTrue(configuration.timeStep.isFinite)
        XCTAssertGreaterThan(configuration.timeStep, 0)
        XCTAssertGreaterThan(configuration.solverIterations, 0)
        XCTAssertGreaterThan(configuration.toiIterationBudget, 0)
        XCTAssertGreaterThan(configuration.contactTolerance, 0)
        XCTAssertGreaterThan(configuration.separationTolerance, configuration.contactTolerance)
        XCTAssertGreaterThan(configuration.maxContourSegmentLength, 0)
        XCTAssertTrue(configuration.linearDamping.isFinite)
        XCTAssertTrue(configuration.angularDamping.isFinite)
        XCTAssertTrue(configuration.surfaceFriction.isFinite)
        XCTAssertEqual(configuration.angularFrictionCoupling, 1)
    }

    func testAngularFrictionCouplingIsClampedToUnitInterval() {
        var configuration = ReferenceConfiguration.default
        configuration.angularFrictionCoupling = 2
        XCTAssertEqual(configuration.sanitized.angularFrictionCoupling, 1)

        configuration.angularFrictionCoupling = -1
        XCTAssertEqual(configuration.sanitized.angularFrictionCoupling, 0)
    }
}
