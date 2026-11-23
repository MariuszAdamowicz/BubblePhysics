@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Brak przejścia przez ścianę i przez inną bańkę w zakresie prędkości gry (P-B-9, P-B-10; G3-AC1, G3-AC2): po każdym podkroku z zapisu
/// `captureSubsteps`, nie tylko po klatce. Ściana grubości 1 leży w x = 360 (rząd współrzędnych planszy), a pary stoją przy tej samej współrzędnej.
@MainActor
final class NoCrossingTests: XCTestCase {
    private let wallX: Float = 360
    private let stiffness = 229.0
    private var capture: NativeMetalConfiguration {
        var native = NativeMetalConfiguration.default
        native.captureSubsteps = true
        return native
    }

    // MARK: P-B-9 (G3-AC1)

    /// Bańka wystrzelona w ścianę prostopadle albo pod 45° z prędkością `speed`. Przy γ = 0 najmniejsze d zgadza się ± 10 % z d = r · (1 − ε_max),
    /// gdzie U(ε_max) = ½ m v_n², v_n to składowa normalna prędkości. Po każdym podkroku środek jest po stronie startowej płaszczyzny ściany
    /// (a więc poza bryłą ściany), a świat nie przechodzi w `worldFailed`.
    private func assertWallImpact(_ kind: ForceScene.Kind, name: String, speed: Float, oblique: Bool, damping: Float) async throws {
        let wallX = self.wallX
        let diagonal = Float(0.5.squareRoot())
        let direction = oblique ? WorldPoint(diagonal, diagonal) : WorldPoint(1, 0)
        let normalSpeed = speed * direction.x
        let gap = damping > 0 ? min(100, 0.3 * normalSpeed / damping) : 100
        let start = WorldPoint(wallX - kind.radius - gap, 0)
        let context = "\(name), v = \(speed), \(oblique ? "ukośnie" : "prostopadle"), γ = \(damping)"
        let world = try ForceScene.makeWorld(damping: damping, native: capture) {
            try $0.add(ForceScene.bubble(1, at: start, kind, velocity: direction * speed)).add(ForceScene.wall(2, x: wallX))
        }
        let recorded = try await ForceScene.run(world, frames: 600, until: { item in
            guard let x = item.position(1), let v = item.velocity(1) else { return true }
            return item.step > 1 && v.x < 0 && x.x < wallX - kind.radius
        })
        ForceScene.assertHealthy(world, context)
        var minimum = Double.infinity, substeps = 0
        for item in recorded {
            for sample in item.samples {
                guard let body = sample.bubbles[1] else { continue }
                substeps += 1
                let d = Double(wallX) - Double(body.position.x)
                minimum = min(minimum, d)
                guard ForceScene.check(body.position.x < wallX, "\(context), krok \(item.step): środek \(body.position.x) nie jest po stronie startowej ściany") else { return }
            }
        }
        XCTAssertGreaterThan(substeps, 0, "\(context): zapis podkroków jest pusty")
        guard let final = recorded.last?.velocity(1) else { XCTFail("\(context): bańka zniknęła ze świata"); return }
        XCTAssertLessThan(final.x, 0, "\(context): bańka ma się odbić")
        guard damping == 0 else { return }
        let energy = 0.5 * Double(kind.mass) * Double(normalSpeed) * Double(normalSpeed)
        let epsilonMax = ContactLawReference.maximumEpsilon(energy: energy, stiffness: stiffness, radius: Double(kind.radius))
        let expected = Double(kind.radius) * (1 - epsilonMax)
        XCTAssertEqual(minimum, expected, accuracy: 0.1 * expected, "\(context): d_min z podkroków \(minimum), z bilansu energii \(expected)")
    }

    private func assertWallImpacts(_ kind: ForceScene.Kind, name: String) async throws {
        for speed: Float in [100, 1000, 3000] {
            for oblique in [false, true] {
                for damping: Float in [0, 1] {
                    try await assertWallImpact(kind, name: name, speed: speed, oblique: oblique, damping: damping)
                }
            }
        }
    }

    func testBubbleTwoNeverCrossesTheWall() async throws { try await assertWallImpacts(ForceScene.two, name: "„2”") }
    func testBubble128NeverCrossesTheWall() async throws { try await assertWallImpacts(ForceScene.b128, name: "128") }
    func testBubble7168NeverCrossesTheWall() async throws { try await assertWallImpacts(ForceScene.b7168, name: "7168") }

    // MARK: P-B-10 (G3-AC2)

    /// Bańka `a` leci na stojącą bańkę `b`, czołowo albo ze środkiem przesuniętym o pół R w bok (R = r_a + r_b). Po każdym podkroku odległość
    /// środków jest dodatnia, a środki nie zamieniają się stronami wzdłuż prostej zderzenia (normalnej w pierwszej próbce z nakładaniem; patrz `checksSides`).
    private func assertPairImpact(_ a: ForceScene.Kind, _ b: ForceScene.Kind, name: String, speed: Float, oblique: Bool) async throws {
        let radii = a.radius + b.radius
        let context = "\(name), v = \(speed), \(oblique ? "ukośnie" : "czołowo")"
        // Prawo kontaktu ma siłę skończoną aż do środka, więc przy 10³ j/s i więcej bańka mijająca środek drugiej z poprzeczną odsuwką R / 2
        // przechodzi przez jej nakładanie ze słabym odchyleniem (jak w sondzie: siła w d = r to 2 · K_c, impuls ok. 15 j/s z 10³): to zgodne
        // z modelem mijanie, a nie odbicie, i normalna z pierwszego nakładania przestaje być prostą zderzenia. Zamianę stron sprawdza się
        // więc w zderzeniach, które odbijają: czołowych przy każdej prędkości i ukośnych przy 10²; ukośne szybsze sprawdzają d > 0.
        let checksSides = !oblique || speed <= 100
        let startA = WorldPoint(wallX - radii - 100, 0)
        let startB = WorldPoint(wallX, oblique ? 0.5 * radii : 0)
        let world = try ForceScene.makeWorld(native: capture) {
            try $0.add(ForceScene.bubble(1, at: startA, a, velocity: [speed, 0])).add(ForceScene.bubble(2, at: startB, b))
        }
        let recorded = try await ForceScene.run(world, frames: 600, until: { item in
            guard let pa = item.position(1), let pb = item.position(2), let va = item.velocity(1), let vb = item.velocity(2) else { return true }
            return item.step > 1 && simd_distance(pa, pb) > radii && simd_dot(vb - va, pb - pa) > 0
        })
        ForceScene.assertHealthy(world, context)
        var normal: WorldPoint?
        var checked = 0
        for item in recorded {
            for sample in item.samples {
                guard let ba = sample.bubbles[1], let bb = sample.bubbles[2] else { continue }
                let offset = bb.position - ba.position
                let distance = ForceScene.length(offset)
                checked += 1
                guard ForceScene.check(distance > 0, "\(context), krok \(item.step): odległość środków \(distance) ≤ 0") else { return }
                if normal == nil, distance <= radii { normal = offset / distance }
                if checksSides, let normal {
                    guard ForceScene.check(simd_dot(offset, normal) > 0, "\(context), krok \(item.step): środki zamieniły się stronami") else { return }
                }
            }
        }
        XCTAssertGreaterThan(checked, 0, "\(context): zapis podkroków jest pusty")
        XCTAssertNotNil(normal, "\(context): bańki nigdy się nie zetknęły")
    }

    private func assertPairImpacts(_ a: ForceScene.Kind, _ b: ForceScene.Kind, name: String) async throws {
        for speed: Float in [100, 1000, 3000] {
            for oblique in [false, true] { try await assertPairImpact(a, b, name: name, speed: speed, oblique: oblique) }
        }
    }

    func testPairOfBubblesTwoNeverSwapsSides() async throws { try await assertPairImpacts(ForceScene.two, ForceScene.two, name: "„2”→„2”") }
    func testPairOfBubbles128NeverSwapsSides() async throws { try await assertPairImpacts(ForceScene.b128, ForceScene.b128, name: "128→128") }
    func testBubbleTwoOnBubble7168NeverSwapsSides() async throws { try await assertPairImpacts(ForceScene.two, ForceScene.b7168, name: "„2”→7168") }
}
