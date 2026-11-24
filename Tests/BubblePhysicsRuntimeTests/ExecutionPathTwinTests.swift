@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Bliźniak ścieżek wykonania (P-B-44; G8-AC4, CD-D-27): te same sceny liczone ścieżką jednej dyspozycji i wymuszoną ścieżką wielu dyspozycji dają
/// ten sam wynik w tolerancjach G4-AC3 (podkroki i przebudowy ±1 na klatkę, suma przebudów ±2, po 1 s pozycje do 1 j, prędkości do 2 % największej).
/// Bliźniak biegnie bez zmniejszonego limitu kandydatów. Każda ścieżka jest sprawdzana osobno w telemetrii, bo bez tego porównanie ścieżki z samą sobą
/// zawsze by przechodziło.
@MainActor
final class ExecutionPathTwinTests: XCTestCase {
    /// Liczy scenę obiema ścieżkami i porównuje.
    @discardableResult
    private func twin(_ scene: PathScene.Scene) async throws -> (single: PathScene.Run, multiple: PathScene.Run) {
        let single = try await PathScene.run(scene, native: PathScene.native(forced: false, minimumMarginOnly: scene.minimumMarginOnly))
        let multiple = try await PathScene.run(scene, native: PathScene.native(forced: true, minimumMarginOnly: scene.minimumMarginOnly))
        PathScene.assertPath(single, .singleDispatch, "\(scene.name), jedna dyspozycja")
        PathScene.assertPath(multiple, .multipleDispatches, "\(scene.name), wiele dyspozycji")
        PathScene.assertHealthy(single, "\(scene.name), jedna dyspozycja")
        PathScene.assertHealthy(multiple, "\(scene.name), wiele dyspozycji")
        PathScene.assertTwin(single, multiple, scene, labels: ("jedna", "wiele"))
        return (single, multiple)
    }

    func testFourSplitScenesGiveTheSameResultInBothPaths() async throws {
        for scene in try PathScene.splitScenes() { try await twin(scene) }
    }

    func testWallStrikeAt3000GivesTheSameResultInBothPaths() async throws {
        try await twin(PathScene.plainWallShot())
    }

    /// G5-AC3 z przebudową siatki: w klatce wybicia jest co najmniej jedna przebudowa (warunek testu), bez przejścia przez ścianę w obu ścieżkach.
    func testKickIntoAWallGivesTheSameResultInBothPaths() async throws {
        let (scene, plan) = PathScene.kick(distractors: false, minimumMarginOnly: true)
        let (single, multiple) = try await twin(scene)
        for (label, run) in [("jedna", single), ("wiele", multiple)] {
            guard run.rebuilds.count > plan.frame else { XCTFail("\(label): za mało klatek"); continue }
            XCTAssertGreaterThanOrEqual(run.rebuilds[plan.frame], 1, "\(label): klatka wybicia ma przebudowę, przebudowy \(run.rebuilds)")
        }
    }

    /// Trzy sceny z przebudową przy bryle (zapas tylko r / 4): bryła kinematyczna z G3-AC3, statyczne koło i statyczna kapsuła z 10³ j/s. W każdej
    /// co najmniej jedna przebudowa zachodzi w klatce kontaktu (warunek testu) w obu ścieżkach.
    func testSceneWithBodiesAndRebuildInTheContactFrameGiveTheSameResultInBothPaths() async throws {
        let scenes = [PathScene.kinematicHit(), PathScene.bodyShot(.circle(radius: 50), name: "koło"),
                      PathScene.bodyShot(.capsule(halfLength: 50, radius: 20), rotation: .pi / 2, name: "kapsuła")]
        for scene in scenes {
            let (single, multiple) = try await twin(scene)
            for (label, run) in [("jedna", single), ("wiele", multiple)] {
                let contact = PathScene.contactFrames(run)
                XCTAssertFalse(contact.isEmpty, "\(scene.name), \(label): bańka nie weszła w kontakt z bryłą")
                XCTAssertTrue(contact.contains { run.rebuilds[$0] >= 1 },
                              "\(scene.name), \(label): żadna klatka kontaktu \(contact) nie ma przebudowy, przebudowy \(run.rebuilds)")
            }
        }
    }

    /// Sceny P-B-43 (para buforów bez przebudowy, ściana i statyczne koło) też zgadzają się między ścieżkami.
    func testContinuationScenesGiveTheSameResultInBothPaths() async throws {
        try await twin(PathScene.Obstacle.wall.scene())
        try await twin(PathScene.Obstacle.circle.scene())
    }

    /// G6-AC5: bryła kinematyczna wciska „2” w ścianę. Obie ścieżki kończą się `worldFailed` z przyczyną przekroczenia limitu podkroków, w tej samej
    /// klatce, z tym samym obiektem wyznaczającym h, a pozycje w ostatniej klatce przed błędem zgadzają się do 1 j.
    func testSubstepLimitFailsInTheSameFrameWithTheSameLimitingObjectInBothPaths() async throws {
        let scene = PathScene.Scene(name: "G6-AC5", frames: 46 + 60 + 5, ids: [1], build: {
            try $0.add(ForceScene.bubble(1, at: [300, 0])).add(ForceScene.wall(2, x: 360))
                .add(ForceScene.square(3, at: [150, 0], side: 100, role: .kinematic))
                .setKinematicDrive(ForceScene.id(3), drive: .velocity(linear: [100, 0], angular: 0))
        })
        let single = try await PathScene.run(scene, native: PathScene.native(forced: false))
        let multiple = try await PathScene.run(scene, native: PathScene.native(forced: true))
        PathScene.assertPath(single, .singleDispatch, "G6-AC5, jedna dyspozycja")
        PathScene.assertPath(multiple, .multipleDispatches, "G6-AC5, wiele dyspozycji")
        for (label, run) in [("jedna", single), ("wiele", multiple)] {
            XCTAssertEqual(run.recorded.last?.issue, .worldFailed, "\(label): świat ma paść z limitu podkroków")
            XCTAssertEqual(run.diagnostics.failureReason, .substepLimitExceeded, label)
        }
        XCTAssertEqual(single.recorded.count, multiple.recorded.count, "ta sama klatka błędu")
        let a = try XCTUnwrap(single.diagnostics.failureDetail), b = try XCTUnwrap(multiple.diagnostics.failureDetail)
        XCTAssertEqual(a.objects, b.objects, "ten sam obiekt wyznaczający h")
        XCTAssertTrue(a.objects.contains(ForceScene.id(1)), "obiektem jest zgniatana bańka, jest \(a.objects)")
        guard single.recorded.count == multiple.recorded.count, single.recorded.count >= 2 else { return }
        let before = single.recorded.count - 2
        let pa = try XCTUnwrap(single.recorded[before].position(1)), pb = try XCTUnwrap(multiple.recorded[before].position(1))
        XCTAssertLessThanOrEqual(simd_distance(pa, pb), 1, "pozycje w ostatniej klatce przed błędem: \(pa) / \(pb)")
    }
}
