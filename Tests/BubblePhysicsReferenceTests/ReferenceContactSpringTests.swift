import XCTest
@testable import BubblePhysicsReference

final class ReferenceContactSpringTests: XCTestCase {
    func testSeparatedContactProducesNoForce() {
        let sample = evaluate(centerA: .init(x: 12, y: 0), centerB: .zero)

        XCTAssertEqual(sample.compression, 0)
        XCTAssertEqual(sample.forceOnA, .zero)
        XCTAssertEqual(sample.tangentStiffness, 0)
    }

    func testTwoUnitsOfCompressionAtStiffnessTenProduceForceTwenty() {
        let sample = evaluate(centerA: .init(x: 8, y: 0), centerB: .zero)

        XCTAssertEqual(sample.compression, 2, accuracy: 1e-6)
        XCTAssertEqual(sample.normal, .init(x: 1, y: 0))
        XCTAssertEqual(sample.forceOnA.x, 20, accuracy: 1e-6)
        XCTAssertEqual(sample.forceOnA.y, 0, accuracy: 1e-6)
        XCTAssertEqual(sample.tangentStiffness, 10, accuracy: 1e-6)
    }

    func testPairForceCanBeAppliedEqualAndOpposite() {
        let sample = evaluate(centerA: .init(x: 8, y: 0), centerB: .zero)

        XCTAssertEqual(sample.forceOnA + (-sample.forceOnA), .zero)
    }

    func testDampingIncreasesApproachingForceButNeverAttractsOnSeparation() {
        let approaching = evaluate(
            centerA: .init(x: 8, y: 0), velocityA: .init(x: -3, y: 0),
            centerB: .zero, velocityB: .zero, damping: 4
        )
        let separatingFast = evaluate(
            centerA: .init(x: 8, y: 0), velocityA: .init(x: 20, y: 0),
            centerB: .zero, velocityB: .zero, damping: 4
        )

        XCTAssertEqual(approaching.forceOnA.x, 32, accuracy: 1e-6)
        XCTAssertEqual(separatingFast.forceOnA, .zero)
    }

    func testCoincidentCentersUseFiniteDeterministicFallback() {
        let sample = evaluate(
            centerA: .zero, centerB: .zero,
            fallback: .init(x: 0, y: 2)
        )

        XCTAssertEqual(sample.normal, .init(x: 0, y: 1))
        XCTAssertTrue(sample.forceOnA.isFinite)
        XCTAssertEqual(sample.forceOnA.y, 100, accuracy: 1e-6)
    }

    func testSurfaceContactUsesPointQAsSpringAnchor() {
        let sample = ReferenceContactSpringState.evaluate(
            centerA: .init(x: 3, y: 0), velocityA: .zero, radiusA: 5,
            centerB: nil, velocityB: .zero, pointQ: .zero,
            normalFallback: .init(x: 1, y: 0), contactDistance: 5,
            stiffness: 10, damping: 0
        )

        XCTAssertEqual(sample.compression, 2, accuracy: 1e-6)
        XCTAssertEqual(sample.forceOnA, .init(x: 20, y: 0))
    }

    private func evaluate(
        centerA: ReferenceVector2,
        velocityA: ReferenceVector2 = .zero,
        centerB: ReferenceVector2,
        velocityB: ReferenceVector2 = .zero,
        fallback: ReferenceVector2 = .init(x: 1, y: 0),
        stiffness: Float = 10,
        damping: Float = 0
    ) -> ReferenceContactSpringSample {
        ReferenceContactSpringState.evaluate(
            centerA: centerA, velocityA: velocityA, radiusA: 5,
            centerB: centerB, velocityB: velocityB, pointQ: nil,
            normalFallback: fallback, contactDistance: 10,
            stiffness: stiffness, damping: damping
        )
    }
}
