import BubblePhysics
import Metal
import XCTest

/// Przyczyna odrzucenia kroku przez strażnika (P-B-15, P-B-16, P-B-36, P-B-37): gra widzi w `lastSolverGuardCause`,
/// czy środek bańki przeszedł przez ścianę albo bryłę, czy bryła przekroczyła budżet próbek obrotu.
/// Wszystko idzie przez publiczny `BubbleWorld` na urządzeniu Metal.
@MainActor
final class SolverGuardCauseTests: XCTestCase {
    private let step = CrowdScene.step
    private let rigidMaterial = PhysicsMaterialID(rawValue: 3)
    private func id(_ value: UInt64) -> ObjectID { CrowdScene.id(value) }

    private func rigid(_ value: UInt64, vertices: [WorldPoint], at position: WorldPoint, role: MotionRole,
                       angularVelocity: Float = 0) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), vertices: vertices, position: position,
                                           angularVelocity: angularVelocity, mass: 2, motionRole: role,
                                           physicsMaterialID: rigidMaterial, renderMaterialID: CrowdScene.style))
    }
    private func box(_ value: UInt64, half: WorldPoint, at position: WorldPoint, role: MotionRole,
                     angularVelocity: Float = 0) throws -> WorldObject {
        try rigid(value, vertices: [[-half.x, -half.y], [half.x, -half.y], [half.x, half.y], [-half.x, half.y]],
                  at: position, role: role, angularVelocity: angularVelocity)
    }
    /// Ramka ścian, bańka przyciśnięta do prawej ściany i bryła kinematyczna poza bańką.
    private func frameWorld(_ extra: (WorldTransaction) throws -> WorldTransaction) async throws -> BubbleWorld {
        try await CrowdScene.makeWorld { setup in
            try extra(setup.updatePhysicsMaterial(self.rigidMaterial, material: try PhysicsMaterial(kind: .rigid)))
        }
    }
    private func advance(_ world: BubbleWorld, _ transaction: WorldTransaction? = nil, steps: Int = 1) async -> WorldFrame {
        if let transaction { _ = world.submit(transaction) }
        var frame = await world.advance(by: 0)
        for _ in 0..<steps { frame = await world.advance(by: step) }
        return frame
    }
    private func assertGuardRejection(_ world: BubbleWorld, cause: SolverGuardCause,
                                      file: StaticString = #filePath, line: UInt = #line) {
        let diagnostics = world.diagnostics
        XCTAssertEqual(diagnostics.lastAdvanceIssue, .stepFailed, file: file, line: line)
        XCTAssertEqual(diagnostics.lastRejectionReason, .solverGuard, file: file, line: line)
        XCTAssertNil(diagnostics.failureReason, "strażnik nie kończy świata", file: file, line: line)
        XCTAssertEqual(diagnostics.lastSolverGuardCause, cause, file: file, line: line)
    }

    // P-B-36
    func testDynamicBodyTurningFasterThanTheSampleBudgetRejectsWithRigidRotationBudget() async throws {
        let world = try await frameWorld { $0 }
        _ = await advance(world, steps: 3)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        // Bryła dynamiczna z materiałem bez `maximumAngularSpeed`; ω > 128 · 0,05 / dt = 384 rad/s.
        _ = await advance(world, WorldTransaction().add(try box(10, half: [20, 0.5], at: .zero, role: .dynamic,
                                                                 angularVelocity: 1_000)))
        assertGuardRejection(world, cause: .rigidRotationBudget)
    }

    // P-B-16
    func testCauseIsNilWithoutAnyRejection() async throws {
        let world = try await frameWorld { $0.add(try CrowdScene.bubble(1, at: [0, 0], radius: 20)) }
        XCTAssertNil(world.diagnostics.lastSolverGuardCause)
        _ = await advance(world, steps: 10)
        XCTAssertNil(world.diagnostics.lastRejectionReason)
        XCTAssertNil(world.diagnostics.lastSolverGuardCause)
    }
}
