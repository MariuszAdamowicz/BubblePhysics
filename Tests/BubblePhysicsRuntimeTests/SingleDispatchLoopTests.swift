@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Ścieżka jednej dyspozycji (P-B-41, P-B-42; G8-AC4, CD-D-27): świat do 1024 baniek liczy krok jednym buforem podkroków, także w klatkach z przebudową
/// siatki wymuszoną zapasem. Warunki samych testów są asercjami: klatka z ≥ 20 podkrokami bez przebudowy, klatka z ≥ 2 przebudowami.
@MainActor
final class SingleDispatchLoopTests: XCTestCase {
    // MARK: P-B-41

    /// „2” w ścianę z 3 · 10³ j/s po klatkach z 1 podkrokiem, w świecie z tłumem 150 baniek w spoczynku z dala od toru. Jest klatka z ≥ 20 podkrokami
    /// bez przebudowy wymuszonej zapasem (bez niej test nie przechodzi) i w każdej takiej klatce telemetria podaje 1 bufor podkroków.
    func testWallStrikeInACrowdedWorldIsOneBufferPerLongFrame() async throws {
        let run = try await PathScene.run(PathScene.wallShot(crowd: 149), native: PathScene.native(forced: false, capture: false))
        PathScene.assertHealthy(run, "uderzenie w tłumie")
        PathScene.assertPath(run, .singleDispatch, "uderzenie w tłumie")
        let substeps = run.substeps, rebuilds = run.rebuilds
        let longFrames = substeps.indices.filter { substeps[$0] >= 20 && rebuilds[$0] == 0 }
        guard let first = longFrames.first else {
            XCTFail("brak klatki z ≥ 20 podkrokami bez przebudowy wymuszonej zapasem, podkroki \(substeps), przebudowy \(rebuilds)")
            return
        }
        XCTAssertTrue(substeps[..<first].contains(1), "uderzenie ma następować po klatce z 1 podkrokiem, podkroki \(substeps)")
        for index in longFrames {
            guard ForceScene.check(run.telemetry[index].substepBufferCount == 1,
                                   "klatka \(index): \(run.telemetry[index].substepBufferCount) buforów podkroków przy \(substeps[index]) podkrokach") else { return }
        }
        XCTAssertLessThan(try XCTUnwrap(run.recorded.last?.velocity(1)).x, 0, "„2” ma odbić się od ściany")
    }

    // MARK: P-B-42

    /// Sceny ścieżki jednej dyspozycji: w każdej klatce 1 bufor podkroków, także w klatkach z przebudową. Scena G5-AC3 (ściana, zapas tylko r / 4)
    /// ma klatkę z co najmniej 2 przebudowami, a telemetria podaje je razem z 1 buforem podkroków.
    func testEverySceneFrameHasOneSubstepBufferAlsoWithRebuilds() async throws {
        let kick = PathScene.kick(distractors: false, minimumMarginOnly: true).scene
        let scenes = [PathScene.wallShot(crowd: 149), kick, PathScene.kinematicHit(),
                      PathScene.bodyShot(.circle(radius: 50), name: "koło"),
                      PathScene.bodyShot(.capsule(halfLength: 50, radius: 20), rotation: .pi / 2, name: "kapsuła")]
        for scene in scenes {
            let run = try await PathScene.run(scene, native: PathScene.native(forced: false, minimumMarginOnly: scene.minimumMarginOnly, capture: false))
            PathScene.assertHealthy(run, scene.name)
            PathScene.assertPath(run, .singleDispatch, scene.name)
            for (index, telemetry) in run.telemetry.enumerated() {
                guard ForceScene.check(telemetry.substepBufferCount == 1,
                                       "\(scene.name), klatka \(index): \(telemetry.substepBufferCount) buforów podkroków, \(telemetry.gridRebuildCount) przebudów") else { return }
            }
            if scene.name == kick.name {
                XCTAssertGreaterThanOrEqual(run.rebuilds.max() ?? 0, 2, "\(scene.name): klatka z ≥ 2 przebudowami, przebudowy \(run.rebuilds)")
            }
        }
    }

    /// G5-AC3 ze ścianą na ścieżce jednej dyspozycji, także z zapasem tylko r / 4: żadna bańka nie przechodzi przez przeszkodę, a klatka wybicia
    /// ma przebudowę z zapasu i 1 bufor podkroków.
    func testKickIntoAThinWallDoesNotCrossAndRebuildsInsideTheKernel() async throws {
        for minimumMarginOnly in [false, true] {
            let (scene, plan) = PathScene.kick(distractors: false, minimumMarginOnly: minimumMarginOnly)
            let front = KickScenePlanner.build(.wall, plan: plan).front
            let context = "minimumMarginOnly = \(minimumMarginOnly)"
            let run = try await PathScene.run(scene, native: PathScene.native(forced: false, minimumMarginOnly: minimumMarginOnly))
            PathScene.assertHealthy(run, context)
            PathScene.assertPath(run, .singleDispatch, context)
            XCTAssertEqual(run.recorded.count, scene.frames, context)
            PathScene.assertNeverBeyond(run, bubble: 2, { $0.x >= front }, context)
            PathScene.assertNeverBeyond(run, bubble: 1, { $0.x >= front }, context)
            guard run.rebuilds.count > plan.frame else { XCTFail("\(context): za mało klatek"); return }
            XCTAssertGreaterThanOrEqual(run.rebuilds[plan.frame], 1, "\(context): klatka wybicia ma przebudowę z zapasu, przebudowy \(run.rebuilds)")
            XCTAssertEqual(run.telemetry[plan.frame].substepBufferCount, 1, context)
        }
    }

    /// CD-D-26: przepełnienie klatki to maksimum po budowach (przed przebudową przepełnia, po niej nie), a nie zero i nie wartość ostatniej budowy.
    func testCandidateOverflowIsTheMaximumOverTheBuildsOfTheFrame() async throws {
        try await PathScene.assertOverflowIsTheMaximumOverBuilds(forced: false)
    }
}
