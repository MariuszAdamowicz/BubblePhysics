@testable import BubblePhysics
import XCTest

/// Scena wybicia z G5-AC3 (CD-D-23) wspólna dla `GridRebuildTests` i testów ścieżek wykonania: bańka 128 (1000 j/s) uderza czołowo lekką „2”
/// w spoczynku i wypycha ją w stronę przeszkody, której „2” nie ma na liście kandydatów na początku kroku. Odstęp startowy dobiera
/// jednowymiarowa symulacja odniesienia w Double.
@MainActor
enum KickScenePlanner {
    static let stiffness = 229.0

    /// Plan sceny z symulacji w Double (współrzędne jednowymiarowe: 128 startuje w 0, „2” przed nią).
    struct Plan {
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
    static func simulate(phase: Double) -> [(frame: Int, x2: Double, v2: Double, path: Double)] {
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
    static func plan() -> Plan {
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
        return Plan(frame: chosen.item.frame, x2: chosen.item.x2, v2: chosen.item.v2, path: chosen.item.path, start128: 0,
                        start2: radii + speed * dt * chosen.phase, lowerForBubble: margin2 + r2 / 4, lowerForWall: margin2,
                        upper: chosen.item.path, margin2: margin2)
    }

    @MainActor enum Obstacle { case wall, bubble }

    /// Środek okna szczeliny: przeszkoda stoi tak, żeby w klatce wybicia „2” ją mijała, a przeszkoda nie była kandydatem na początku kroku.
    static func gap(_ obstacle: Obstacle, plan: Plan) -> Float {
        let lower = obstacle == .wall ? plan.lowerForWall : plan.lowerForBubble
        return Float(lower + 0.4 * (plan.upper - lower))
    }

    /// Obiekty sceny: 128 (ID 1) i „2” (ID 2) przesunięte tak, żeby „2” stała w x = 300 na początku klatki wybicia, przeszkoda (ID 3) za nią.
    /// Zwraca też współrzędną czoła przeszkody (płaszczyznę ściany albo środek bańki minus promień).
    static func build(_ obstacle: Obstacle, plan: Plan) -> (build: (WorldTransaction) throws -> WorldTransaction, front: Float) {
        let offset = 300 - plan.x2
        let x128 = Float(offset + plan.start128), x2 = Float(offset + plan.start2)
        let front = Float(300 + 24) + gap(obstacle, plan: plan)
        return ({ setup in
            let base = try setup.add(ForceScene.bubble(1, at: [x128, 0], ForceScene.b128, velocity: [1000, 0]))
                .add(ForceScene.bubble(2, at: [x2, 0]))
            switch obstacle {
            case .wall: return try base.add(ForceScene.wall(3, x: front))
            case .bubble: return try base.add(ForceScene.bubble(3, at: [front + 24, 0]))
            }
        }, front)
    }
}
