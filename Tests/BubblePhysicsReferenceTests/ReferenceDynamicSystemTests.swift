import XCTest
@testable import BubblePhysicsReference

final class ReferenceDynamicSystemTests: XCTestCase {
    func testNoForcesPreserveConstantVelocity() {
        let system = makeSystem(
            centers: [.init(x: 1, y: 2)],
            velocities: [.init(x: 3, y: -4)],
            masses: [2]
        )
        let endCenters = [ReferenceVector2(x: 1.3, y: 1.6)]

        assertVector(system.velocities(forEndCenters: endCenters)[0], .init(x: 3, y: -4))
        assertVector(system.residual(endCenters: endCenters)[0], .zero, accuracy: 3e-6)
    }

    func testGlobalDragReducesSpeedWithoutChangingDirection() {
        let system = makeSystem(
            centers: [.zero], velocities: [.init(x: 10, y: 0)], masses: [2], globalDrag: 4
        )
        let expectedEndVelocity = Float(20.0 / 3.0)
        let endCenters = [ReferenceVector2(x: (10 + expectedEndVelocity) * 0.05, y: 0)]
        let endVelocity = system.velocities(forEndCenters: endCenters)[0]

        XCTAssertGreaterThan(endVelocity.x, 0)
        XCTAssertLessThan(endVelocity.x, 10)
        assertVector(endVelocity, .init(x: expectedEndVelocity, y: 0), accuracy: 1e-5)
        assertVector(system.residual(endCenters: endCenters)[0], .zero, accuracy: 1e-5)
    }

    func testSingleCompressedSpringProducesOutwardAcceleration() {
        let system = makeSystem(
            centers: [.init(x: 8, y: 0)], velocities: [.zero], masses: [2],
            contacts: [surfaceContact(anchor: .zero)], stiffness: 10
        )

        let residual = system.residual(endCenters: [.init(x: 8, y: 0)])[0]

        XCTAssertEqual(residual.x, -4, accuracy: 1e-6)
        XCTAssertEqual(residual.y, 0, accuracy: 1e-6)
    }

    func testEqualOppositeSpringsProduceZeroAcceleration() {
        let system = makeSystem(
            centers: [.zero], velocities: [.zero], masses: [2],
            contacts: [
                surfaceContact(anchor: .init(x: -8, y: 0), fallback: .init(x: 1, y: 0)),
                surfaceContact(anchor: .init(x: 8, y: 0), fallback: .init(x: -1, y: 0))
            ],
            stiffness: 10
        )

        assertVector(system.residual(endCenters: [.zero])[0], .zero)
    }

    func testExactOneDimensionalMidpointSolutionHasZeroResidual() {
        let system = makeSystem(
            centers: [.init(x: 8, y: 0)], velocities: [.zero], masses: [2],
            contacts: [surfaceContact(anchor: .zero)], stiffness: 10
        )
        let exactEndX = Float(332.0 / 41.0)

        assertVector(
            system.residual(endCenters: [.init(x: exactEndX, y: 0)])[0],
            .zero,
            accuracy: 2e-5
        )
    }

    func testJacobianVectorAgreesWithIndependentFiniteDifference() {
        let contact = ReferenceDynamicContact(
            indexA: 0, indexB: 1, pointQ: nil, contactDistance: 10,
            normalFallback: .init(x: -1, y: 0)
        )
        let system = makeSystem(
            centers: [.init(x: 0, y: 0), .init(x: 8, y: 1)],
            velocities: [.init(x: 0.2, y: -0.1), .init(x: -0.3, y: 0.2)],
            masses: [2, 3], contacts: [contact], stiffness: 13, contactDamping: 2, globalDrag: 0.5
        )
        let end = [ReferenceVector2(x: 0.03, y: -0.01), .init(x: 7.96, y: 1.04)]
        let direction = [ReferenceVector2(x: 0.7, y: -0.4), .init(x: -0.2, y: 0.5)]
        let epsilon: Float = 1e-3
        let plus = zip(end, direction).map { $0 + $1 * epsilon }
        let minus = zip(end, direction).map { $0 - $1 * epsilon }
        let expected = zip(system.residual(endCenters: plus), system.residual(endCenters: minus))
            .map { ($0 - $1) / (2 * epsilon) }

        let actual = system.applyJacobian(at: end, to: direction)

        XCTAssertEqual(actual.count, expected.count)
        for index in actual.indices {
            assertVector(actual[index], expected[index], accuracy: 1e-3)
        }
    }

    private func makeSystem(
        centers: [ReferenceVector2],
        velocities: [ReferenceVector2],
        masses: [Float],
        contacts: [ReferenceDynamicContact] = [],
        stiffness: Float = 0,
        contactDamping: Float = 0,
        globalDrag: Float = 0
    ) -> ReferenceDynamicSystem {
        ReferenceDynamicSystem(
            startCenters: centers,
            startVelocities: velocities,
            masses: masses,
            radii: Array(repeating: 5, count: centers.count),
            contacts: contacts,
            timeStep: 0.1,
            stiffness: stiffness,
            contactDamping: contactDamping,
            globalDrag: globalDrag
        )
    }

    private func surfaceContact(
        anchor: ReferenceVector2,
        fallback: ReferenceVector2 = .init(x: 1, y: 0)
    ) -> ReferenceDynamicContact {
        .init(
            indexA: 0, indexB: nil, pointQ: anchor,
            contactDistance: 10, normalFallback: fallback
        )
    }

    private func assertVector(
        _ actual: ReferenceVector2,
        _ expected: ReferenceVector2,
        accuracy: Float = 1e-6,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }
}
