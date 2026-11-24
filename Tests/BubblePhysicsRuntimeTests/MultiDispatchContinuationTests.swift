@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Kontynuacja par buforów w wymuszonej ścieżce wielu dyspozycji (P-B-43; G8-AC4, CD-D-29): para k > 0 bez przebudowy kontynuuje na sąsiedztwie
/// z poprzedniej pary, a bufor końca kroku pary niekońcowej nie podmienia tego sąsiedztwa na kontakty końca kroku. Błąd byłby widoczny zawsze,
/// gdy przeszkoda jest kandydatem, ale nie aktywnym kontaktem na końcu pierwszej pary (warunek testu), bo drugą parę policzyłby warunek d / 4
/// na sąsiedztwie bez wierszy brył.
@MainActor
final class MultiDispatchContinuationTests: XCTestCase {
    /// Zapas obwiedni „2” jadącej 3000 j/s na początku klatki: 1,05 · v · dt = 52,5 j (bez sił a₀ = 0). Start w odległości 36 j od przeszkody.
    private let margin: Float = 1.05 * PathScene.Obstacle.speed / 60

    private func assertContinuation(_ obstacle: PathScene.Obstacle) async throws {
        let scene = obstacle.scene()
        let context = "\(obstacle)"
        let run = try await PathScene.run(scene, native: PathScene.native(forced: true))
        PathScene.assertHealthy(run, context)
        PathScene.assertPath(run, .multipleDispatches, context)
        XCTAssertEqual(run.recorded.count, scene.frames, context)
        // Warunki testu: klatka 0 ma co najmniej 2 pary buforów bez przebudowy, przeszkoda jest kandydatem (36 j < zapas 52,5 j), a po pierwszej
        // parze (2 podkroki) bańka nie dotyka jeszcze przeszkody (środek dalej niż r od jej powierzchni).
        let first = try XCTUnwrap(run.telemetry.first, "\(context): brak telemetrii")
        XCTAssertGreaterThanOrEqual(first.substepBufferCount, 2, "\(context): klatka 0 ma mieć co najmniej 2 pary buforów")
        XCTAssertEqual(first.gridRebuildCount, 0, "\(context): między parami nie ma przebudowy z zapasu")
        // Przeszkoda jest kandydatem: dla ściany to obserwacja silnika (w klatce 0 jedna budowa siatki, a w świecie jest jedna bańka, więc każdy
        // skompaktowany kandydat to odcinek ściany). Bryła statyczna idzie osobnymi wierszami brył, których `candidatePairCount` nie liczy, więc dla
        // koła zostaje warunek na stałych sceny (odstęp 36 j mniejszy niż zapas 52,5 j).
        switch obstacle {
        case .wall: XCTAssertGreaterThan(first.candidatePairCount, 0, "\(context): ściana ma być kandydatem w klatce 0")
        case .circle: XCTAssertLessThan(PathScene.Obstacle.gap, margin, "\(context): przeszkoda ma być kandydatem")
        }
        let samples = try XCTUnwrap(run.recorded.first?.samples)
        guard samples.count >= 3, let afterFirstPair = samples[1].bubbles[1]?.position else {
            XCTFail("\(context): zapis klatki 0 ma co najmniej 3 podkroki, jest \(samples.count)")
            return
        }
        switch obstacle {
        case .wall: XCTAssertGreaterThan(obstacle.surface - afterFirstPair.x, 24, "\(context): po pierwszej parze bańka dotyka ściany")
        case .circle: XCTAssertGreaterThan(ForceScene.length(afterFirstPair), 50 + 24, "\(context): po pierwszej parze bańka dotyka koła")
        }
        // Wynik: środek „2” po każdym podkroku po stronie startowej przeszkody, odbicie i brak `worldFailed`.
        PathScene.assertNeverBeyond(run, obstacle.isBeyond, context)
        XCTAssertLessThan(try XCTUnwrap(run.recorded.last?.velocity(1)).x, 0, "\(context): „2” ma odbić się od przeszkody")
    }

    func testSecondPairKeepsTheWallAsACandidateAndBubbleDoesNotCrossIt() async throws {
        try await assertContinuation(.wall)
    }

    func testSecondPairKeepsTheStaticCircleAsACandidateAndBubbleDoesNotCrossIt() async throws {
        try await assertContinuation(.circle)
    }

    /// Przepełnienie klatki w wymuszonej ścieżce wielu dyspozycji też jest maksimum po budowach klatki (CD-D-26), a przebudowa jest tylko po
    /// znaczniku, nie przed każdą parą: klatka wybicia ma co najmniej 1 przebudowę, a pary liczą się osobno od przebudów (P-B-40).
    func testOverflowIsTheMaximumOverBuildsAlsoInTheMultipleDispatchPath() async throws {
        try await PathScene.assertOverflowIsTheMaximumOverBuilds(forced: true)
    }

    func testPairsWithoutAMarginMarkerDoNotRebuildTheGrid() async throws {
        let (scene, plan) = PathScene.kick(distractors: false, minimumMarginOnly: false)
        let run = try await PathScene.run(scene, native: PathScene.native(forced: true))
        PathScene.assertHealthy(run, scene.name)
        PathScene.assertPath(run, .multipleDispatches, scene.name)
        let telemetry = try XCTUnwrap(run.telemetry.indices.contains(plan.frame) ? run.telemetry[plan.frame] : nil)
        // Pierwsza para buduje siatkę sama, a każda przebudowa z zapasu zaczyna nową parę: pary = 1 + przebudowy + pary kontynuowane bez przebudowy.
        XCTAssertGreaterThanOrEqual(telemetry.substepBufferCount, telemetry.gridRebuildCount + 1,
                                    "pary: \(telemetry.substepBufferCount), przebudowy z zapasu: \(telemetry.gridRebuildCount)")
        XCTAssertGreaterThanOrEqual(telemetry.gridRebuildCount, 1, "klatka wybicia ma przebudowę z zapasu")
        // Ścisła nierówność dowodzi, że istnieje para kontynuowana bez przebudowy (gdyby każda para po pierwszej przebudowywała siatkę, byłoby
        // pary = 1 + przebudowy). W samej klatce wybicia pary i przebudowy zgadzają się co do jednej (3 pary, 2 przebudowy), a para bez przebudowy
        // jest w klatce tuż po niej (długa klatka z 42 podkrokami: 2 pary, 0 przebudów), więc szukamy jej od klatki wybicia.
        let continued = run.telemetry.indices.filter { index in
            index >= plan.frame && run.telemetry[index].substepBufferCount > run.telemetry[index].gridRebuildCount + 1
        }
        XCTAssertFalse(continued.isEmpty,
                       "od klatki wybicia ma być klatka z parą kontynuowaną bez przebudowy; pary / przebudowy: \(run.telemetry.map { "\($0.substepBufferCount)/\($0.gridRebuildCount)" })")
    }
}
