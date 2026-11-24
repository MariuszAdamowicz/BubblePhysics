@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Zapas obwiedni i przebudowa siatki w klatce wybicia (P-B-20; G5-AC3, CD-D-23): bańka 128 (1000 j/s) uderza czołowo lekką „2” w spoczynku
/// i wypycha ją w stronę przeszkody, której „2” nie ma na liście kandydatów na początku kroku (zapas „2” z początku kroku to r / 4 = 6 j).
/// Odstęp startowy dobiera jednowymiarowa symulacja odniesienia tak, żeby w klatce wybicia szczelina była większa niż suma zapasów obu
/// obiektów, ale mniejsza niż droga „2” w tym kroku. Wariant z bańką 128 jako przeszkodą (zapas 16 j) jest niewykonalny i nie wchodzi do testu.
@MainActor
final class GridRebuildTests: XCTestCase {
    private let stiffness = 229.0

    private typealias KickPlan = KickScenePlanner.Plan
    private func plan() -> KickPlan { KickScenePlanner.plan() }

    func testPlannerFindsAWindowForBothObstacles() {
        let plan = plan()
        XCTAssertGreaterThan(plan.upper - plan.lowerForBubble, 3, "okno szczeliny dla bańki: \(plan.lowerForBubble)…\(plan.upper)")
        XCTAssertGreaterThan(plan.upper - plan.lowerForWall, 3, "okno szczeliny dla ściany: \(plan.lowerForWall)…\(plan.upper)")
        XCTAssertGreaterThan(plan.frame, 0, "wybicie nie następuje w pierwszej klatce")
    }

    private enum Obstacle { case wall, bubble }

    /// Scena: 128 i „2” przesunięte tak, żeby „2” stała w x = 300 na początku klatki wybicia, przeszkoda za nią w środku okna szczeliny.
    private func assertNoCrossing(_ obstacle: Obstacle, minimumMarginOnly: Bool) async throws {
        let plan = plan()
        let planned = KickScenePlanner.build(obstacle == .wall ? .wall : .bubble, plan: plan)
        let front = planned.front
        let gap = KickScenePlanner.gap(obstacle == .wall ? .wall : .bubble, plan: plan)
        let lower = obstacle == .wall ? plan.lowerForWall : plan.lowerForBubble
        var native = NativeMetalConfiguration.default
        native.captureSubsteps = true
        native.minimumMarginOnly = minimumMarginOnly
        let context = "\(obstacle), minimumMarginOnly = \(minimumMarginOnly), szczelina \(gap) z okna \(lower)…\(plan.upper), klatka \(plan.frame)"
        let world = try ForceScene.makeWorld(native: native, build: planned.build)
        let recorded = try await ForceScene.run(world, frames: plan.frame + 8)
        ForceScene.assertHealthy(world, context)
        XCTAssertEqual(recorded.count, plan.frame + 8, context)
        var checked = 0
        for item in recorded {
            for sample in item.samples {
                guard let a = sample.bubbles[1], let b = sample.bubbles[2] else { continue }
                checked += 1
                guard ForceScene.check(b.position.x - a.position.x > 0, "\(context), krok \(item.step): „2” i 128 zamieniły się stronami") else { return }
                switch obstacle {
                case .wall:
                    guard ForceScene.check(b.position.x < front && a.position.x < front,
                                           "\(context), krok \(item.step): środek \(b.position.x) przeszedł przez ścianę w \(front)") else { return }
                case .bubble:
                    guard let c = sample.bubbles[3] else { continue }
                    guard ForceScene.check(c.position.x - b.position.x > 0 && c.position.x - a.position.x > 0,
                                           "\(context), krok \(item.step): bańki zamieniły się stronami") else { return }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "\(context): zapis podkroków jest pusty")
        // Przebudowa wymuszona zapasem obwiedni (znacznik `h_zapasu`), nie każda para po pierwszej: para, która tylko wyczerpała swoje podkroki,
        // też zaczyna od przebudowy, ale nie dowodzi, że zapas działa. Klatka wybicia ma ją mieć sama, bez okna ±1 klatki.
        let margin = recorded.map { $0.telemetry?.gridRebuildCount ?? 0 }
        guard ForceScene.check(plan.frame < margin.count, "\(context): zapisano tylko \(margin.count) klatek") else { return }
        XCTAssertGreaterThanOrEqual(margin[plan.frame], 1, "\(context): klatka wybicia ma dać przebudowę z powodu zapasu, przebudowy z zapasu \(margin)")
    }

    func testLightBubbleKickedIntoAThinWallDoesNotCrossItAndTheGridIsRebuilt() async throws {
        try await assertNoCrossing(.wall, minimumMarginOnly: false)
    }

    func testLightBubbleKickedIntoAnotherBubbleDoesNotCrossItAndTheGridIsRebuilt() async throws {
        try await assertNoCrossing(.bubble, minimumMarginOnly: false)
    }

    /// CD-D-23: ta sama scena z zapasem tylko r / 4 dla wszystkich baniek daje ten sam brak przejścia.
    func testSameScenesWithMinimumMarginOnlyDoNotCrossEither() async throws {
        try await assertNoCrossing(.wall, minimumMarginOnly: true)
        try await assertNoCrossing(.bubble, minimumMarginOnly: true)
    }
}
