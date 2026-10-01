import XCTest
import simd
@testable import BubblePhysicsMetal

final class BubbleMaterialAxisTests: XCTestCase {
    func testAngleDoesNotJumpAcrossMinusPiBoundary() {
        var axis = BubbleMaterialAxis()
        let before = axis.update(materialSamples: samples(angle: .pi - 0.05, count: 8), deltaTime: 1 / 60)
        let after = axis.update(materialSamples: samples(angle: -.pi + 0.05, count: 8), deltaTime: 1 / 60)

        XCTAssertLessThan(abs(after - before), 0.2)
    }

    func testSingleLocalImpulseDoesNotRotateLabelAbruptly() {
        var axis = BubbleMaterialAxis()
        _ = axis.update(materialSamples: samples(angle: 0, count: 8), deltaTime: 1 / 60)
        var deformed = samples(angle: 0, count: 8)
        deformed[0] = SIMD2<Float>(0, 1)

        let angle = axis.update(materialSamples: deformed, deltaTime: 1 / 60)

        XCTAssertLessThan(abs(angle), 0.08)
    }

    func testSustainedMaterialRotationRemainsVisible() {
        var axis = BubbleMaterialAxis()
        _ = axis.update(materialSamples: samples(angle: 0, count: 8), deltaTime: 1 / 60)
        var angle: Float = 0
        for frame in 1...120 {
            let target = Float(frame) / 120
            angle = axis.update(materialSamples: samples(angle: target, count: 8), deltaTime: 1 / 60)
        }

        XCTAssertGreaterThan(angle, 0.8)
        XCTAssertLessThan(abs(axis.angularVelocity), 2)
    }

    func testChangingSampleCountKeepsMaterialAxisContinuous() {
        var axis = BubbleMaterialAxis()
        let before = axis.update(materialSamples: samples(angle: 0.7, count: 8), deltaTime: 1 / 60)
        let after = axis.update(materialSamples: samples(angle: 0.7, count: 17), deltaTime: 1 / 60)

        XCTAssertLessThan(abs(after - before), 0.01)
    }

    private func samples(angle: Float, count: Int) -> [SIMD2<Float>] {
        (0..<count).map { index in
            let local = angle + Float(index) * 0.08 - Float(count - 1) * 0.04
            return SIMD2(cos(local), sin(local))
        }
    }
}
