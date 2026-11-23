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

    /// Plan sceny z symulacji w Double (współrzędne jednowymiarowe: 128 startuje w 0, „2” przed nią).
    private struct KickPlan {
        var frame: Int
        /// Położenie „2” na początku klatki wybicia i jej prędkość.
        var x2: Double
        var v2: Double
        /// Droga „2” w klatce wybicia.
        var path: Double
        /// Środek 128 na początku symulacji i „2” (odstęp startowy to dotyk plus droga 128 w ułamku klatki z fazy zetknięcia).
        var start128: Double
        var start2: Double
        /// Najmniejsza i największa szczelina, przy której przeszkoda nie jest kandydatem na początku kroku, a „2” ją mija w kroku.
        var lowerForBubble: Double
        var lowerForWall: Double
        var upper: Double
        /// Zapas „2” na początku klatki wybicia: max(1,05 · |v| · dt, r / 4).
        var margin2: Double
    }

    /// Jednowymiarowa symulacja 128 + „2” (ta sama sztywność, prawo pary ε = δ / R) z faza zetknięcia `phase` ∈ [0, 1) klatki: dla każdej klatki
    /// położenie i prędkość „2” na jej początku oraz droga w klatce.
    private func simulate(phase: Double) -> [(frame: Int, x2: Double, v2: Double, path: Double)] {
        let r128 = 64.0, r2 = 24.0, m128 = Double(ForceScene.b128.mass), m2 = 1.0, speed = 1000.0, dt = 1.0 / 60
        let radii = r128 + r2
        var x128 = 0.0, v128 = speed
        var x2 = radii + speed * dt * phase, v2 = 0.0
        let h = dt / 4000
        func force(_ a: Double, _ b: Double) -> Double {
            ContactLawReference.force(epsilon: (radii - (b - a)) / radii, stiffness: stiffness)
        }
        var frames: [(frame: Int, x2: Double, v2: Double, path: Double)] = []
        for frame in 0..<16 {
            let startX2 = x2, startV2 = v2
            for _ in 0..<4000 {
                var f = force(x128, x2)
                v128 += 0.5 * h * (-f / m128); v2 += 0.5 * h * (f / m2)
                x128 += h * v128; x2 += h * v2
                f = force(x128, x2)
                v128 += 0.5 * h * (-f / m128); v2 += 0.5 * h * (f / m2)
            }
            frames.append((frame, startX2, startV2, x2 - startX2))
        }
        return frames
    }

    /// Faza zetknięcia i klatka, w której „2” zaczyna z małą prędkością (zapas „2” na początku klatki to r / 4 = 6 j, z zapasem bezpieczeństwa:
    /// 1,05 · |v| · dt ≤ 5 j) i robi największą drogę. Okno szczeliny to (zapas „2” + zapas przeszkody, droga „2”).
    private func plan() -> KickPlan {
        let dt = 1.0 / 60, r2 = 24.0, radii = 88.0, speed = 1000.0
        var best: (phase: Double, item: (frame: Int, x2: Double, v2: Double, path: Double))?
        for step in 0..<50 {
            let phase = Double(step) / 50
            for item in simulate(phase: phase) where 1.05 * abs(item.v2) * dt <= 5 && item.path > (best?.item.path ?? 0) {
                best = (phase, item)
            }
        }
        let chosen = best!
        let margin2 = max(1.05 * abs(chosen.item.v2) * dt, r2 / 4)
        return KickPlan(frame: chosen.item.frame, x2: chosen.item.x2, v2: chosen.item.v2, path: chosen.item.path, start128: 0,
                        start2: radii + speed * dt * chosen.phase, lowerForBubble: margin2 + r2 / 4, lowerForWall: margin2,
                        upper: chosen.item.path, margin2: margin2)
    }

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
        let lower = obstacle == .wall ? plan.lowerForWall : plan.lowerForBubble
        let gap = lower + 0.4 * (plan.upper - lower)
        let offset = 300 - plan.x2
        let x128 = Float(offset + plan.start128), x2 = Float(offset + plan.start2)
        let front = Float(300 + 24 + gap)
        var native = NativeMetalConfiguration.default
        native.captureSubsteps = true
        native.minimumMarginOnly = minimumMarginOnly
        let context = "\(obstacle), minimumMarginOnly = \(minimumMarginOnly), szczelina \(gap) z okna \(lower)…\(plan.upper), klatka \(plan.frame)"
        let world = try ForceScene.makeWorld(native: native) { setup in
            let base = try setup.add(ForceScene.bubble(1, at: [x128, 0], ForceScene.b128, velocity: [1000, 0]))
                .add(ForceScene.bubble(2, at: [x2, 0]))
            switch obstacle {
            case .wall: return try base.add(ForceScene.wall(3, x: front))
            case .bubble: return try base.add(ForceScene.bubble(3, at: [front + 24, 0]))
            }
        }
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
        let rebuilds = recorded.map { $0.telemetry?.gridRebuildCount ?? 0 }
        if minimumMarginOnly {
            XCTAssertGreaterThanOrEqual(rebuilds.reduce(0, +), 1, "\(context): przebudowy \(rebuilds)")
        } else {
            let around = rebuilds[max(0, plan.frame - 1)...min(rebuilds.count - 1, plan.frame + 1)].reduce(0, +)
            XCTAssertGreaterThanOrEqual(around, 1, "\(context): klatka wybicia ma dać co najmniej jedną przebudowę, przebudowy \(rebuilds)")
        }
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
