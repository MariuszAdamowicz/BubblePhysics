import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

final class ReferenceMetalDynamicSystemTests: XCTestCase {
    // Missing midpoint/contact forces, the FD stencil, or contact coefficients
    // each break an independent comparison with the existing CPU oracle.
    func testBubbleBubbleResidualMatchesCPU() async throws {
        let fixture = try makeFixture(segment: false)
        let result = try await evaluate(fixture)
        assertVectors(result.residual, fixture.system.residual(endCenters: fixture.end))
    }

    func testBubbleSegmentResidualMatchesCPU() async throws {
        let fixture = try makeFixture(segment: true)
        let result = try await evaluate(fixture)
        assertVectors(result.residual, fixture.system.residual(endCenters: fixture.end))
    }

    func testBubbleBubbleJacobianMatchesCPU() async throws {
        let fixture = try makeFixture(segment: false)
        let result = try await evaluate(fixture)
        assertVectors(result.jacobianVector, fixture.system.applyJacobian(at: fixture.end, to: fixture.vector))
    }

    func testBubbleSegmentJacobianMatchesCPU() async throws {
        let fixture = try makeFixture(segment: true)
        let result = try await evaluate(fixture)
        assertVectors(result.jacobianVector, fixture.system.applyJacobian(at: fixture.end, to: fixture.vector))
    }

    func testInverseDiagonalMatchesCPUForBothContactKinds() async throws {
        for segment in [false, true] {
            let fixture = try makeFixture(segment: segment)
            let result = try await evaluate(fixture)
            assertVectors(result.inverseDiagonal, fixture.system.inverseDiagonalPreconditioner(at: fixture.end))
        }
    }

    func testJacobianOfZeroIsExactlyZeroForBothContactKinds() async throws {
        for segment in [false, true] {
            let fixture = try makeFixture(segment: segment)
            let solver = try makeSolver()
            let result = try await solver.evaluateOperatorsForTesting(
                snapshot: fixture.snapshot, endCenters: fixture.end,
                vector: Array(repeating: .zero, count: fixture.vector.count))
            XCTAssertEqual(result.jacobianVector, Array(repeating: .zero, count: fixture.vector.count))
            XCTAssertEqual(result.dotProduct, 0)
        }
    }

    // The CPU zero-vector guard precedes residual evaluation, even for NaN centers.
    func testJacobianOfZeroBypassesNonFiniteResidual() async throws {
        let fixture = try makeFixture(segment: true)
        let result = try await makeSolver().evaluateOperatorsForTesting(snapshot: fixture.snapshot,
            endCenters: [.init(x: .nan, y: 0)], vector: [.zero])
        XCTAssertEqual(result.jacobianVector, [.zero])
        XCTAssertEqual(result.dotProduct, 0)
    }

    func testContactNormalFallbackAndSeparatedContactMatchCPU() async throws {
        let fixtures = try [
            makeFixture(segment: true, centerA: .init(x: -4, y: 0), end: [.init(x: -3.9, y: 0)]),
            makeFixture(segment: false, centerA: .zero, centerB: .zero, end: [.zero, .zero]),
            makeFixture(segment: false, end: [.init(x: -30, y: 0), .init(x: 38, y: 1)])
        ]
        for fixture in fixtures {
            let result = try await evaluate(fixture)
            assertVectors(result.residual, fixture.system.residual(endCenters: fixture.end))
            assertVectors(result.jacobianVector, fixture.system.applyJacobian(at: fixture.end, to: fixture.vector))
        }
    }

    func testRepeatedEvaluationsRefreshBuffersAndShrinkActiveCounts() async throws {
        let solver = try makeSolver()
        for segment in [false, true, false] {
            let fixture = try makeFixture(segment: segment)
            let result = try await solver.evaluateOperatorsForTesting(snapshot: fixture.snapshot,
                endCenters: fixture.end, vector: fixture.vector)
            assertVectors(result.residual, fixture.system.residual(endCenters: fixture.end))
            assertVectors(result.jacobianVector, fixture.system.applyJacobian(at: fixture.end, to: fixture.vector))
            let expectedDot = zip(fixture.vector, fixture.system.applyJacobian(at: fixture.end, to: fixture.vector))
                .reduce(Float(0)) { $0 + $1.0.dot($1.1) }
            XCTAssertEqual(result.dotProduct, expectedDot, accuracy: 1e-3)
        }
    }

    func testEmptySnapshotReturnsEmptyVectorsAndZeroDot() async throws {
        let snapshot = ReferenceMetalSnapshot(world: ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase()))
        let result = try await makeSolver().evaluateOperatorsForTesting(snapshot: snapshot, endCenters: [], vector: [])
        XCTAssertEqual(result.residual, [])
        XCTAssertEqual(result.jacobianVector, [])
        XCTAssertEqual(result.inverseDiagonal, [])
        XCTAssertEqual(result.dotProduct, 0)
    }

    func testMismatchedVectorCountThrowsBeforeGPUDispatch() async throws {
        let fixture = try makeFixture(segment: true)
        do {
            _ = try await makeSolver().evaluateOperatorsForTesting(snapshot: fixture.snapshot, endCenters: fixture.end, vector: [])
            XCTFail("Expected invalid input")
        } catch ReferenceMetalOperatorError.invalidInput { }
    }

    // 513 rows cross two full reduction blocks and one partial block. With
    // dt=.125, mass=2, drag=0, J=32I and v=(.25,-.5): v·Jv=513*10.
    func testDotReductionIncludesPartialBlockInFixedOrder() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 0.125, linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for index in 0..<513 {
            world.addBubble(try .init(id: .init(rawValue: index), center: .zero, mass: 2, targetRadius: 1))
        }
        let snapshot = ReferenceMetalSnapshot(world: world)
        let solver = try makeSolver()
        let result = try await solver.evaluateOperatorsForTesting(
            snapshot: snapshot, endCenters: Array(repeating: .zero, count: 513),
            vector: Array(repeating: .init(x: 0.25, y: -0.5), count: 513))
        XCTAssertEqual(result.dotProduct, 5130, accuracy: 1e-3)
    }

    private struct Fixture {
        let snapshot: ReferenceMetalSnapshot
        let system: ReferenceDynamicSystem
        let end: [ReferenceVector2]
        let vector: [ReferenceVector2]
    }

    private func makeFixture(segment: Bool, centerA: ReferenceVector2? = nil, centerB: ReferenceVector2? = nil,
                             end: [ReferenceVector2]? = nil) throws -> Fixture {
        let configuration = ReferenceConfiguration(timeStep: 0.1, nonlinearStiffening: 3,
            linearDamping: 0.5, contactStiffness: 13, contactDamping: 2)
        var world = ReferenceWorld(configuration: configuration, broadPhase: BruteForceBroadPhase())
        var a = try ReferenceBubble(id: .init(rawValue: -17),
            center: .init(x: segment ? 4 : 0, y: 0), velocity: .init(x: 0.2, y: -0.1), mass: 2, targetRadius: 5)
        var b = try ReferenceBubble(id: .init(rawValue: 8_000_000_000),
            center: .init(x: 8, y: 1), velocity: .init(x: -0.3, y: 0.2), mass: 3, targetRadius: 5)
        world.addBubble(a)
        if segment {
            world.addSegment(.staticSegment(id: .init(rawValue: 99), a: .init(x: 0, y: -10), b: .init(x: 0, y: 10)))
        } else { world.addBubble(b) }
        _ = world.step()
        XCTAssertFalse(world.contacts.contacts.isEmpty)
        if let centerA { a.center = centerA }
        if let centerB { b.center = centerB }
        world.updateBubble(a)
        if !segment { world.updateBubble(b) }
        let snapshot = ReferenceMetalSnapshot(world: world)
        let ids = Dictionary(uniqueKeysWithValues: snapshot.bubbles.indices.map { (snapshot.bubbles[$0].identity.x, $0) })
        let contacts = snapshot.contacts.compactMap { contact -> ReferenceDynamicContact? in
            guard let indexA = ids[contact.bubbles.x] else { return nil }
            let indexB = contact.identity.y & 2 != 0 ? ids[contact.bubbles.y] : nil
            return .init(indexA: indexA, indexB: indexB,
                pointQ: indexB == nil ? .init(x: contact.geometry.z, y: contact.geometry.w) : nil,
                contactDistance: snapshot.bubbles[indexA].physical.z + (indexB.map { snapshot.bubbles[$0].physical.z } ?? 0),
                normalFallback: .init(x: contact.geometry.x * (indexB == nil ? 1 : -1), y: contact.geometry.y * (indexB == nil ? 1 : -1)))
        }
        let system = ReferenceDynamicSystem(startCenters: snapshot.centers.map { .init(x: $0.x, y: $0.y) },
            startVelocities: snapshot.velocities.map { .init(x: $0.x, y: $0.y) },
            masses: snapshot.bubbles.map { $0.physical.x }, radii: snapshot.bubbles.map { $0.physical.z }, contacts: contacts,
            timeStep: configuration.timeStep, stiffness: configuration.contactStiffness, nonlinearStiffening: configuration.nonlinearStiffening,
            contactDamping: configuration.contactDamping, globalDrag: configuration.linearDamping)
        return Fixture(snapshot: snapshot, system: system,
            end: end ?? (segment ? [.init(x: 4.03, y: -0.01)] : [.init(x: 0.03, y: -0.01), .init(x: 7.96, y: 1.04)]),
            vector: segment ? [.init(x: 0.7, y: -0.4)] : [.init(x: 0.7, y: -0.4), .init(x: -0.2, y: 0.5)])
    }

    private func makeSolver() throws -> ReferenceMetalSolver {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return try XCTUnwrap(ReferenceMetalSolver(device: device))
    }

    private func evaluate(_ fixture: Fixture) async throws -> ReferenceMetalOperatorResult {
        try await makeSolver().evaluateOperatorsForTesting(snapshot: fixture.snapshot, endCenters: fixture.end, vector: fixture.vector)
    }

    private func assertVectors(_ actual: [ReferenceVector2], _ expected: [ReferenceVector2], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-3, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-3, file: file, line: line)
        }
    }
}
