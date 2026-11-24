@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Granica progu ścieżek wykonania (P-B-45; G8-AC4, CD-D-27): uderzenie z P-B-41 z 1024 bańkami liczy się jedną dyspozycją, z 1025 wieloma, a transakcja
/// usuwająca bańkę ze świata 1025 baniek przełącza ścieżkę od kroku, który ją przyjął (transakcja wchodzi przed `advance` tego kroku). W każdym wariancie środek „2” po każdym podkroku jest poza ścianą
/// i po stronie startowej, a świat nie przechodzi w `worldFailed`.
@MainActor
final class ExecutionPathThresholdTests: XCTestCase {
    private func assertStrike(crowd: Int, path: NativeMetalExecutionPath, _ context: String) async throws {
        let run = try await PathScene.run(PathScene.wallShot(crowd: crowd), native: PathScene.native(forced: false))
        PathScene.assertHealthy(run, context)
        PathScene.assertPath(run, path, context)
        PathScene.assertNeverBeyond(run, { $0.x >= PathScene.wallX }, context)
        XCTAssertLessThan(try XCTUnwrap(run.recorded.last?.velocity(1)).x, 0, "\(context): „2” ma odbić się od ściany")
        XCTAssertGreaterThan(run.substeps.max() ?? 0, 1, "\(context): uderzenie ma dać klatkę z podkrokami")
    }

    func testWorldWith1024BubblesUsesTheSingleDispatchPath() async throws {
        try await assertStrike(crowd: 1023, path: .singleDispatch, "1024 bańki")
    }

    func testWorldWith1025BubblesUsesMultipleDispatches() async throws {
        try await assertStrike(crowd: 1024, path: .multipleDispatches, "1025 baniek")
    }

    /// Transakcja usuwa bańkę ze świata 1025 baniek: kroki przed nią liczą się wieloma dyspozycjami, kroki od niej (krok 2 dostaje transakcję
    /// przed `advance`, więc ma już 1024 bańki) jedną.
    func testTransactionRemovingABubbleSwitchesThePathFromTheNextStep() async throws {
        let removalStep = 2
        var scene = PathScene.wallShot(crowd: 1024)
        scene.before = { step in step == removalStep ? WorldTransaction().remove(ForceScene.id(1000)) : nil }
        let run = try await PathScene.run(scene, native: PathScene.native(forced: false))
        PathScene.assertHealthy(run, "usunięcie bańki")
        XCTAssertGreaterThan(run.recorded.count, removalStep + 2, "przebieg ma objąć kroki po transakcji")
        XCTAssertEqual(run.telemetry[removalStep].executionPath, .singleDispatch, "krok transakcji liczy już 1024 bańki jedną dyspozycją")
        for (index, telemetry) in run.telemetry.enumerated() {
            if index < removalStep {
                guard ForceScene.check(telemetry.executionPath == .multipleDispatches, "krok \(index) przed transakcją: ścieżka \(telemetry.executionPath)") else { return }
            } else {
                guard ForceScene.check(telemetry.executionPath == .singleDispatch, "krok \(index) od transakcji: ścieżka \(telemetry.executionPath)") else { return }
            }
        }
        PathScene.assertNeverBeyond(run, { $0.x >= PathScene.wallX }, "usunięcie bańki")
        XCTAssertLessThan(try XCTUnwrap(run.recorded.last?.velocity(1)).x, 0, "„2” ma odbić się od ściany")
    }
}
