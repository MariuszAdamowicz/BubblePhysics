import XCTest
@testable import BubblePhysicsReference

final class ReferenceDeformationLawTests: XCTestCase {
    func testZeroRequiredCompressionProducesZeroStress() {
        let stress = ReferenceDeformationLaw.solve(
            requiredCompression: 0, radiusA: 8, stiffnessA: 2,
            radiusB: 8, stiffnessB: 2, nonlinearStiffening: 8
        )
        XCTAssertEqual(stress, .zero)
    }

    func testRigidSegmentAssignsAllCompressionToBubble() {
        let stress = ReferenceDeformationLaw.solve(
            requiredCompression: 6, radiusA: 10, stiffnessA: 2,
            nonlinearStiffening: 8
        )
        XCTAssertEqual(stress.compressionA, 6, accuracy: 0.0001)
        XCTAssertEqual(stress.compressionB, 0)
    }

    func testEqualBubblesSplitCompressionEqually() {
        let stress = ReferenceDeformationLaw.solve(
            requiredCompression: 6, radiusA: 10, stiffnessA: 2,
            radiusB: 10, stiffnessB: 2, nonlinearStiffening: 8
        )
        XCTAssertEqual(stress.compressionA, 3, accuracy: 0.0001)
        XCTAssertEqual(stress.compressionB, 3, accuracy: 0.0001)
    }

    func testSofterBubbleTakesMoreCompression() {
        let stress = ReferenceDeformationLaw.solve(
            requiredCompression: 6, radiusA: 10, stiffnessA: 1,
            radiusB: 10, stiffnessB: 4, nonlinearStiffening: 8
        )
        XCTAssertGreaterThan(stress.compressionA, stress.compressionB)
    }

    func testPressureAndTangentStiffnessIncreaseNonlinearly() {
        let shallow = ReferenceDeformationLaw.solve(
            requiredCompression: 1, radiusA: 10, stiffnessA: 2,
            nonlinearStiffening: 8
        )
        let deep = ReferenceDeformationLaw.solve(
            requiredCompression: 8, radiusA: 10, stiffnessA: 2,
            nonlinearStiffening: 8
        )
        XCTAssertGreaterThan(deep.pressure, shallow.pressure)
        XCTAssertGreaterThan(deep.effectiveStiffness, shallow.effectiveStiffness)
    }

    func testFullRadiusCompressionRemainsFinite() {
        let stress = ReferenceDeformationLaw.solve(
            requiredCompression: 8, radiusA: 8, stiffnessA: 2,
            nonlinearStiffening: 8
        )
        XCTAssertTrue(stress.compressionA.isFinite)
        XCTAssertTrue(stress.pressure.isFinite)
        XCTAssertTrue(stress.effectiveStiffness.isFinite)
    }
}
