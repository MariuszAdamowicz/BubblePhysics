import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

final class ReferenceMetalPCGTests: XCTestCase {
    // Wrong recurrence, preconditioner, or iteration accounting breaks the
    // comparison with the existing CPU solver operating on the same system.
    func testContactCorrectionsAndIterationCountsMatchCPU() async throws {
        let solver = try makeSolver()
        for segment in [false, true] {
            let fixture = try makeFixture(segment: segment)
            let rhs = fixture.system.residual(endCenters: fixture.end).map { -$0 }
            for limit in [1, 8] {
                let expected = cpu(fixture, rhs: rhs, limit: limit)
                let actual = try await solver.solvePCGForTesting(snapshot: fixture.snapshot,
                    endCenters: fixture.end, rightHandSide: rhs, limit: limit)
                assertResult(actual, expected)
            }
        }
    }

    // J=32I, diagonal=1/32: one iteration gives (1/32,-1/16).
    // An unguarded later dispatch would divide by zero or alter this result.
    func testConvergenceAtLimitEightFreezesAfterOneIteration() async throws {
        let fixture = try makeDiagonalFixture()
        let actual = try await makeSolver().solvePCGForTesting(snapshot: fixture.snapshot,
            endCenters: fixture.end, rightHandSide: [.init(x: 1, y: -2)], limit: 8)
        XCTAssertEqual(actual.iterationCount, 1)
        assertVectors(actual.solution, [.init(x: 0.03125, y: -0.0625)])
        XCTAssertEqual(actual.initialResidualNorm, Float(5).squareRoot(), accuracy: 1e-3)
        XCTAssertLessThanOrEqual(actual.finalResidualNorm, 0.001 * actual.initialResidualNorm)
        XCTAssertFalse(actual.hasNonFiniteState)
    }

    func testThresholdConvergenceFreezesANonzeroResidual() async throws {
        let fixture = try makeFixture(segment: false, tolerance: 0.1)
        let rhs = fixture.system.residual(endCenters: fixture.end).map { -$0 }
        let expected = cpu(fixture, rhs: rhs, limit: 8)
        XCTAssertEqual(expected.iterationCount, 1)
        XCTAssertGreaterThan(expected.finalResidualNorm, 0.1)
        let actual = try await makeSolver().solvePCGForTesting(snapshot: fixture.snapshot,
            endCenters: fixture.end, rightHandSide: rhs, limit: 8)
        assertResult(actual, expected)
    }

    // A missing final partial block changes alpha; stale row counts on the next
    // call contaminate the one-bubble solve. Expected solutions are hand-derived.
    func testReductionAcross513RowsAndReuseWithSmallerInput() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 0.125, linearDamping: 0), broadPhase: BruteForceBroadPhase())
        for index in 0..<513 {
            world.addBubble(try .init(id: .init(rawValue: index), center: .zero, mass: 2, targetRadius: 1))
        }
        let solver = try makeSolver()
        var rhs = Array(repeating: ReferenceVector2(x: 1, y: -2), count: 513)
        rhs[512] = .init(x: 32, y: -64)
        var expected = Array(repeating: ReferenceVector2(x: 0.03125, y: -0.0625), count: 513)
        expected[512] = .init(x: 1, y: -2)
        let result = try await solver.solvePCGForTesting(snapshot: .init(world: world),
            endCenters: Array(repeating: .zero, count: 513),
            rightHandSide: rhs, limit: 8)
        assertVectors(result.solution, expected)
        XCTAssertEqual(result.iterationCount, 1)
        XCTAssertFalse(result.hasNonFiniteState)
        XCTAssertEqual(result.initialResidualNorm, Float(7680).squareRoot(), accuracy: 1e-3)
        let small = try makeDiagonalFixture()
        let smallRHS = [ReferenceVector2(x: -3, y: 4)]
        let next = try await solver.solvePCGForTesting(snapshot: small.snapshot,
            endCenters: small.end, rightHandSide: smallRHS, limit: 8)
        assertResult(next, cpu(small, rhs: smallRHS, limit: 8))
    }

    func testZeroAndEmptyRightHandSidesConvergeWithoutIteration() async throws {
        let solver = try makeSolver()
        let fixture = try makeDiagonalFixture()
        let zero = try await solver.solvePCGForTesting(snapshot: fixture.snapshot,
            endCenters: fixture.end, rightHandSide: [.zero], limit: 8)
        assertResult(zero, cpu(fixture, rhs: [.zero], limit: 8))
        let empty = ReferenceMetalSnapshot(world: ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase()))
        let result = try await solver.solvePCGForTesting(snapshot: empty, endCenters: [], rightHandSide: [], limit: 8)
        XCTAssertEqual(result.solution, [])
        XCTAssertEqual(result.iterationCount, 0)
        XCTAssertEqual(result.initialResidualNorm, 0)
        XCTAssertEqual(result.finalResidualNorm, 0)
        XCTAssertFalse(result.hasNonFiniteState)
    }

    func testNonPositiveLimitsLeaveCorrectionAtZero() async throws {
        let fixture = try makeDiagonalFixture()
        let solver = try makeSolver()
        for limit in [0, -8] {
            let rhs = [ReferenceVector2(x: 1, y: -2)]
            let result = try await solver.solvePCGForTesting(snapshot: fixture.snapshot,
                endCenters: fixture.end, rightHandSide: rhs, limit: limit)
            assertResult(result, cpu(fixture, rhs: rhs, limit: limit))
        }
    }

    func testSmallDenominatorStopsBeforeUpdatingCorrection() async throws {
        let fixture = try makeDiagonalFixture()
        let rhs = [ReferenceVector2(x: 0.0001, y: 0)]
        let expected = cpu(fixture, rhs: rhs, limit: 8)
        XCTAssertEqual(expected.iterationCount, 0)
        let actual = try await makeSolver().solvePCGForTesting(snapshot: fixture.snapshot,
            endCenters: fixture.end, rightHandSide: rhs, limit: 8)
        assertResult(actual, expected)
    }

    func testNonFiniteRightHandSideIsReportedBeforeIteration() async throws {
        let fixture = try makeDiagonalFixture()
        let solver = try makeSolver()
        for value: Float in [.infinity, .nan] {
            let actual = try await solver.solvePCGForTesting(snapshot: fixture.snapshot,
                endCenters: fixture.end, rightHandSide: [.init(x: value, y: 0)], limit: 8)
            XCTAssertTrue(actual.hasNonFiniteState)
            XCTAssertEqual(actual.iterationCount, 0)
            XCTAssertEqual(actual.solution, [.zero])
            XCTAssertEqual(actual.initialResidualNorm, 0)
            XCTAssertEqual(actual.finalResidualNorm, 0)
        }
    }

    func testNonFiniteJacobianIsReportedBeforeUpdatingCorrection() async throws {
        let fixture = try makeDiagonalFixture()
        let result = try await makeSolver().solvePCGForTesting(snapshot: fixture.snapshot,
            endCenters: [.init(x: .nan, y: 0)], rightHandSide: [.init(x: 1, y: -2)], limit: 8)
        XCTAssertTrue(result.hasNonFiniteState)
        XCTAssertEqual(result.iterationCount, 0)
        XCTAssertEqual(result.solution, [.zero])
        XCTAssertEqual(result.finalResidualNorm, Float(5).squareRoot(), accuracy: 1e-3)
    }

    func testMismatchedCountsAreRejected() async throws {
        let fixture = try makeDiagonalFixture()
        do {
            _ = try await makeSolver().solvePCGForTesting(snapshot: fixture.snapshot,
                endCenters: fixture.end, rightHandSide: [], limit: 8)
            XCTFail("Expected invalid input")
        } catch ReferenceMetalOperatorError.invalidInput { }
    }

    private struct Fixture {
        let snapshot: ReferenceMetalSnapshot
        let system: ReferenceDynamicSystem
        let end: [ReferenceVector2]
    }

    private func makeDiagonalFixture() throws -> Fixture {
        let config = ReferenceConfiguration(timeStep: 0.125, linearDamping: 0)
        var world = ReferenceWorld(configuration: config, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 2, targetRadius: 1))
        return .init(snapshot: .init(world: world), system: .init(startCenters: [.zero], startVelocities: [.zero],
            masses: [2], radii: [1], contacts: [], timeStep: 0.125, stiffness: config.contactStiffness,
            contactDamping: config.contactDamping, globalDrag: 0), end: [.zero])
    }

    private func makeFixture(segment: Bool, tolerance: Float = 0.001) throws -> Fixture {
        let config = ReferenceConfiguration(timeStep: 0.1, nonlinearStiffening: 3,
            linearDamping: 0.5, pcgTolerance: tolerance, contactStiffness: 13, contactDamping: 2)
        var world = ReferenceWorld(configuration: config, broadPhase: BruteForceBroadPhase())
        let a = try ReferenceBubble(id: .init(rawValue: -17), center: .init(x: segment ? 4 : 0, y: 0),
            velocity: .init(x: 0.2, y: -0.1), mass: 2, targetRadius: 5)
        let b = try ReferenceBubble(id: .init(rawValue: 8_000_000_000), center: .init(x: 8, y: 1),
            velocity: .init(x: -0.3, y: 0.2), mass: 3, targetRadius: 5)
        world.addBubble(a)
        if segment {
            world.addSegment(.staticSegment(id: .init(rawValue: 99), a: .init(x: 0, y: -10), b: .init(x: 0, y: 10)))
        } else { world.addBubble(b) }
        _ = world.step()
        XCTAssertEqual(world.contacts.contacts.count, 1)
        world.updateBubble(a)
        if !segment { world.updateBubble(b) }
        let snapshot = ReferenceMetalSnapshot(world: world)
        let contact = try XCTUnwrap(world.contacts.contacts.first)
        let system = ReferenceDynamicSystem(startCenters: segment ? [a.center] : [a.center, b.center],
            startVelocities: segment ? [a.velocity] : [a.velocity, b.velocity], masses: segment ? [2] : [2, 3],
            radii: segment ? [5] : [5, 5], contacts: [.init(indexA: 0, indexB: segment ? nil : 1,
                pointQ: segment ? contact.pointQ : nil, contactDistance: segment ? 5 : 10,
                normalFallback: segment ? contact.normal : -contact.normal)], timeStep: config.timeStep,
            stiffness: config.contactStiffness, nonlinearStiffening: config.nonlinearStiffening,
            contactDamping: config.contactDamping, globalDrag: config.linearDamping)
        return .init(snapshot: snapshot, system: system,
            end: segment ? [.init(x: 4.03, y: -0.01)] : [.init(x: 0.03, y: -0.01), .init(x: 7.96, y: 1.04)])
    }

    private func cpu(_ fixture: Fixture, rhs: [ReferenceVector2], limit: Int) -> ReferencePCGResult {
        ReferencePCGSolver.solve(rightHandSide: rhs, apply: { fixture.system.applyJacobian(at: fixture.end, to: $0) },
            inverseDiagonal: fixture.system.inverseDiagonalPreconditioner(at: fixture.end),
            tolerance: fixture.snapshot.configuration.pcgTolerance, iterationLimit: limit)
    }

    private func makeSolver() throws -> ReferenceMetalSolver {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("Metal unavailable") }
        return try XCTUnwrap(ReferenceMetalSolver(device: device))
    }

    private func assertResult(_ actual: ReferencePCGResult, _ expected: ReferencePCGResult,
                              file: StaticString = #filePath, line: UInt = #line) {
        assertVectors(actual.solution, expected.solution, file: file, line: line)
        XCTAssertEqual(actual.iterationCount, expected.iterationCount, file: file, line: line)
        XCTAssertEqual(actual.initialResidualNorm, expected.initialResidualNorm, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(actual.finalResidualNorm, expected.finalResidualNorm, accuracy: 1e-3, file: file, line: line)
        XCTAssertEqual(actual.hasNonFiniteState, expected.hasNonFiniteState, file: file, line: line)
    }

    private func assertVectors(_ actual: [ReferenceVector2], _ expected: [ReferenceVector2],
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, b) in zip(actual, expected) {
            XCTAssertEqual(a.x, b.x, accuracy: 1e-3, file: file, line: line)
            XCTAssertEqual(a.y, b.y, accuracy: 1e-3, file: file, line: line)
        }
    }
}
