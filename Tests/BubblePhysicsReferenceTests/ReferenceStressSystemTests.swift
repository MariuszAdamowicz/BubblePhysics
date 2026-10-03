import XCTest
@testable import BubblePhysicsReference

final class ReferenceStressSystemTests: XCTestCase {
    func testPairContactProducesEqualOppositeResiduals() {
        let system = makeSystem(
            masses: [1, 1],
            contributions: [.init(indexA: 0, indexB: 1, normal: .init(x: 1, y: 0), pressure: 3, effectiveStiffness: 4)]
        )
        let residual = system.residual(centers: [.zero, .zero])
        XCTAssertEqual(residual, [.init(x: 3, y: 0), .init(x: -3, y: 0)])
    }

    func testOpposingContactsCancelMiddleResidual() {
        let system = makeSystem(
            masses: [1],
            contributions: [
                .init(indexA: 0, indexB: nil, normal: .init(x: 1, y: 0), pressure: 5, effectiveStiffness: 2),
                .init(indexA: 0, indexB: nil, normal: .init(x: -1, y: 0), pressure: 5, effectiveStiffness: 2),
            ]
        )
        XCTAssertEqual(system.residual(centers: [.zero])[0], .zero)
    }

    func testInertiaAnchorsIsolatedBubbleAtPredictedCenter() {
        let system = ReferenceStressSystem(
            masses: [2], predictedCenters: [.init(x: 4, y: 0)], linearizationCenters: [.init(x: 4, y: 0)],
            timeStep: 0.5, contributions: []
        )
        XCTAssertEqual(system.residual(centers: [.init(x: 5, y: 0)])[0], .init(x: 8, y: 0))
    }

    func testJacobianIsPositiveDefiniteAndSymmetric() {
        let system = makeSystem(
            masses: [1, 2],
            contributions: [.init(indexA: 0, indexB: 1, normal: .init(x: 0.6, y: 0.8), pressure: 3, effectiveStiffness: 7)]
        )
        let u = [ReferenceVector2(x: 2, y: -1), .init(x: 0.5, y: 3)]
        let v = [ReferenceVector2(x: -1, y: 4), .init(x: 2, y: 0.25)]
        let ju = system.applyJacobian(to: u)
        let jv = system.applyJacobian(to: v)

        XCTAssertGreaterThan(dot(u, ju), 0)
        XCTAssertEqual(dot(u, jv), dot(ju, v), accuracy: 0.00001)
    }

    private func makeSystem(masses: [Float], contributions: [ReferenceStressContribution]) -> ReferenceStressSystem {
        ReferenceStressSystem(
            masses: masses,
            predictedCenters: Array(repeating: .zero, count: masses.count),
            linearizationCenters: Array(repeating: .zero, count: masses.count),
            timeStep: 1,
            contributions: contributions
        )
    }

    private func dot(_ a: [ReferenceVector2], _ b: [ReferenceVector2]) -> Float {
        zip(a, b).reduce(0) { $0 + $1.0.dot($1.1) }
    }
}
