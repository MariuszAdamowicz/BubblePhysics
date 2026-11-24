@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Siatka haszowana w grupie z kolizjami kubełków (P-B-46; G8-AC4): z `gridHashBucketCount` = 1 każda komórka koliduje ze wszystkimi, a mimo to żadna
/// para nie trafia do wiersza kandydatów ani do sąsiedztwa dwa razy (wpis kubełka przechowuje swoją komórkę). Podwójna para podwoiłaby siłę kontaktu
/// i zawyżyła liczbę kandydatów, więc test porównuje przebieg z jednym kubełkiem z przebiegiem z 2048 kubełkami: liczbę kandydatów na obiekt w każdej klatce
/// łączną liczbę skompaktowanych kandydatów (telemetria `candidatePairCount`, suma po wszystkich wierszach, więc duplikat w wierszu niemaksymalnym też ją zmienia)
/// oraz wynik w tolerancjach bliźniaka (P-B-44).
@MainActor
final class InGroupGridCollisionTests: XCTestCase {
    private func assertSameAsWithTheDefaultBuckets(_ scene: PathScene.Scene) async throws {
        let colliding = try await PathScene.run(scene, native: PathScene.native(forced: false, minimumMarginOnly: scene.minimumMarginOnly, buckets: 1))
        let regular = try await PathScene.run(scene, native: PathScene.native(forced: false, minimumMarginOnly: scene.minimumMarginOnly, buckets: 2048))
        PathScene.assertPath(colliding, .singleDispatch, "\(scene.name), 1 kubełek")
        PathScene.assertPath(regular, .singleDispatch, "\(scene.name), 2048 kubełków")
        PathScene.assertHealthy(colliding, "\(scene.name), 1 kubełek")
        PathScene.assertHealthy(regular, "\(scene.name), 2048 kubełków")
        XCTAssertGreaterThanOrEqual(regular.maximumCandidates.max() ?? 0, 2, "\(scene.name): scena ma mieć kandydatów, inaczej test nic nie dowodzi")
        XCTAssertEqual(colliding.maximumCandidates, regular.maximumCandidates,
                       "\(scene.name): liczba kandydatów na obiekt w klatce nie zależy od liczby kubełków, \(colliding.maximumCandidates) / \(regular.maximumCandidates)")
        // Maksimum na obiekt nie zdradza duplikatu w wierszu niemaksymalnym; suma skompaktowanych kandydatów tak.
        XCTAssertGreaterThanOrEqual(regular.candidatePairs.min() ?? -1, 0, "\(scene.name): telemetria każdej klatki")
        XCTAssertGreaterThanOrEqual(regular.candidatePairs.max() ?? 0, 2, "\(scene.name): scena ma mieć kandydatów w sumie")
        XCTAssertEqual(colliding.candidatePairs, regular.candidatePairs,
                       "\(scene.name): łączna liczba kandydatów w klatce nie zależy od liczby kubełków, \(colliding.candidatePairs) / \(regular.candidatePairs)")
        XCTAssertEqual(colliding.overflow, regular.overflow, "\(scene.name): przepełnienie klatek")
        XCTAssertEqual(colliding.overflow.reduce(0, +), 0, "\(scene.name): podwójne wpisy nie mogą zapełniać wierszy")
        PathScene.assertTwin(colliding, regular, scene, labels: ("1 kubełek", "2048 kubełków"))
    }

    /// Uderzenie z P-B-41 w tłumie 150 baniek: sąsiedzi tłumu są kandydatami, a do 9 komórek wokół bańki trafia ten sam kubełek.
    func testWallStrikeInACrowdIsTheSameWithOneBucket() async throws {
        var scene = PathScene.wallShot(crowd: 149)
        scene.ids = [1, 1000, 1001, 1030]
        try await assertSameAsWithTheDefaultBuckets(scene)
    }

    /// G5-AC3 z przebudową (ściana, zapas tylko r / 4): kandydaci po przebudowie w jądrze też nie powtarzają par przy jednym kubełku.
    func testKickIntoAWallWithRebuildIsTheSameWithOneBucket() async throws {
        let (scene, plan) = PathScene.kick(distractors: false, minimumMarginOnly: true)
        try await assertSameAsWithTheDefaultBuckets(scene)
        let rebuilt = try await PathScene.run(scene, native: PathScene.native(forced: false, minimumMarginOnly: true, buckets: 1))
        XCTAssertGreaterThanOrEqual(rebuilt.rebuilds.max() ?? 0, 1, "przebudowa w jądrze przy jednym kubełku, przebudowy \(rebuilt.rebuilds), klatka wybicia \(plan.frame)")
    }
}
