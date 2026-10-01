import XCTest
@testable import BubblePhysics

final class SpringMaterialTests: XCTestCase {
    func testSpringForceIsOddAndMonotonicAcrossDeepCompression() {
        let material = SpringMaterial(quadraticStiffness: 12, quarticStiffness: 3, drag: 0.4)
        let compressions: [Float] = [-0.1, -0.5, -0.9]
        let magnitudes = compressions.map { abs(material.springForce(extension: $0)) }

        for value in compressions {
            XCTAssertEqual(material.springForce(extension: value), -material.springForce(extension: -value), accuracy: 0.000_01)
        }
        XCTAssertLessThan(magnitudes[0], magnitudes[1])
        XCTAssertLessThan(magnitudes[1], magnitudes[2])
    }

    func testForceAndCorrectionRemainFiniteNearZeroLength() {
        let material = SpringMaterial(quadraticStiffness: 25, quarticStiffness: 8, drag: 0.8)
        let force = material.springForce(extension: 1e-7 - 1)
        let correction = material.implicitLengthCorrection(extension: 1e-7 - 1, inverseMassSum: 2, deltaTime: 1 / 60)

        XCTAssertTrue(force.isFinite)
        XCTAssertTrue(correction.isFinite)
    }

    func testDragUsesExponentialDecayIndependentOfStepSubdivision() {
        let material = SpringMaterial(quadraticStiffness: 1, quarticStiffness: 0, drag: 1.25)
        let whole = material.velocityScale(deltaTime: 1)
        let subdivided = pow(material.velocityScale(deltaTime: 0.1), 10)

        XCTAssertEqual(whole, exp(-1.25), accuracy: 0.000_01)
        XCTAssertEqual(subdivided, whole, accuracy: 0.000_01)
    }
}
