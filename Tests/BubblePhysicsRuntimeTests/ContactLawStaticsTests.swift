@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Statyka prawa kontaktu F = K_c · ε / (1 − ε)² w świecie na GPU (P-B-4, P-B-5, P-B-6; G2-AC1, G2-AC2, G2-AC3), z odniesieniem w Double
/// z `ContactLawReference`. Sceny stoją blisko początku układu, żeby położenia Float miały drobną rozdzielczość: ściana leży w x = d*,
/// środek bańki w 0, więc d = x_ściany − x_środka mierzy się z dokładnością rzędu 1e-7.
@MainActor
final class ContactLawStaticsTests: XCTestCase {
    private let stiffness = 229.0

    // MARK: P-B-4 (G2-AC1)

    /// Bańka dociśnięta do ściany stałą siłą, start w spoczynku w d*, γ = 0, 20 s: |d − d*| ≤ 0,5 % · d* + 1e-3 w każdej klatce, d > 0.
    private func assertWallEquilibrium(_ kind: ForceScene.Kind, force: Float, name: String, frames: Int = 1200) async throws {
        let dStar = ContactLawReference.equilibriumDistance(force: Double(force), stiffness: stiffness, radius: Double(kind.radius))
        let wallX = Float(dStar)
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: .zero, kind)).add(ForceScene.wall(2, x: wallX)).setGlobalForce([force, 0])
        }
        let recorded = try await ForceScene.run(world, frames: frames)
        ForceScene.assertHealthy(world, "\(name), F = \(force)")
        XCTAssertEqual(recorded.count, frames, "\(name), F = \(force): przebieg ma objąć wszystkie klatki")
        for item in recorded {
            guard let x = item.position(1) else { XCTFail("\(name), F = \(force): bańka zniknęła w kroku \(item.step)"); return }
            let d = Double(wallX) - Double(x.x)
            guard ForceScene.check(d > 0, "\(name), F = \(force), krok \(item.step): d = \(d) ≤ 0"),
                  ForceScene.check(abs(d - dStar) <= 0.005 * dStar + 1e-3,
                                   "\(name), F = \(force), krok \(item.step): d = \(d), d* = \(dStar)") else { return }
        }
    }

    func testBubbleTwoPressedToWallHoldsEquilibriumDistance() async throws {
        for force: Float in [100, 1200, 10_000, 20_000, 100_000] {
            try await assertWallEquilibrium(ForceScene.two, force: force, name: "„2”")
        }
    }

    func testBubble7168PressedToWallHoldsEquilibriumDistance() async throws {
        for force: Float in [100, 1200, 10_000, 20_000, 100_000] {
            try await assertWallEquilibrium(ForceScene.b7168, force: force, name: "7168")
        }
    }

    /// Para tego samego materiału ściśnięta dwoma polami kierunkowymi (każde na jedną bańkę, siły równe i przeciwne): R = r_a + r_b zamiast r,
    /// d* = R · (1 − ε*), γ = 0, 20 s.
    private func assertPairEquilibrium(_ a: ForceScene.Kind, _ b: ForceScene.Kind, force: Float, name: String) async throws {
        let radii = Double(a.radius) + Double(b.radius)
        let dStar = radii * (1 - ContactLawReference.epsilon(forForceRatio: Double(force) / stiffness))
        let half = Float(dStar / 2)
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [-half, 0], a)).add(ForceScene.bubble(2, at: [half, 0], b))
                .add(ForceScene.push(3, on: 1, force: [force, 0], around: .zero))
                .add(ForceScene.push(4, on: 2, force: [-force, 0], around: .zero))
        }
        let recorded = try await ForceScene.run(world, frames: 1200)
        ForceScene.assertHealthy(world, "\(name), F = \(force)")
        XCTAssertEqual(recorded.count, 1200, "\(name), F = \(force): przebieg ma objąć wszystkie klatki")
        for item in recorded {
            guard let pa = item.position(1), let pb = item.position(2) else { XCTFail("\(name): bańka zniknęła"); return }
            let d = Double(simd_distance(pa, pb))
            guard ForceScene.check(d > 0, "\(name), F = \(force), krok \(item.step): d = \(d) ≤ 0"),
                  ForceScene.check(abs(d - dStar) <= 0.005 * dStar + 1e-3,
                                   "\(name), F = \(force), krok \(item.step): d = \(d), d* = \(dStar)") else { return }
        }
    }

    func testPairOfBubblesTwoHoldsEquilibriumDistance() async throws {
        for force: Float in [100, 1200, 10_000, 20_000, 100_000] {
            try await assertPairEquilibrium(ForceScene.two, ForceScene.two, force: force, name: "„2”–„2”")
        }
    }

    func testBubbleTwoAndBubble7168PairHoldsEquilibriumDistance() async throws {
        for force: Float in [100, 1200, 10_000, 20_000, 100_000] {
            try await assertPairEquilibrium(ForceScene.two, ForceScene.b7168, force: force, name: "„2”–7168")
        }
    }

    // MARK: P-B-5 (G2-AC2)

    /// Odwrotność prawa w float32 wobec Double: bańka dociśnięta siłą F = q · K_c do ściany przy q od 1e-4 do 1e6 ma średnie ugięcie
    /// ε = 1 − d / r równe ε(q) z Double z błędem względnym ≤ 1e-3. Średnia z 4 s (kilka okresów drgań wokół równowagi, bo γ = 0).
    /// Przy q = 1e6 bańka „2” potrzebowałaby ponad 1024 podkroków na klatkę, więc ten przypadek liczy bańka 7168.
    func testInverseOfTheLawAgreesWithDoubleAcrossForceRatios() async throws {
        let ratios: [Double] = [1e-4, 1e-3, 1e-2, 1e-1, 1, 10, 100, 1e3, 1e4, 1e5, 1e6]
        for q in ratios {
            let kind = q >= 1e6 ? ForceScene.b7168 : ForceScene.two
            let force = Float(q * stiffness)
            let expected = ContactLawReference.epsilon(forForceRatio: Double(force) / stiffness)
            let wallX = Float(Double(kind.radius) * (1 - expected))
            let world = try ForceScene.makeWorld {
                try $0.add(ForceScene.bubble(1, at: .zero, kind)).add(ForceScene.wall(2, x: wallX)).setGlobalForce([force, 0])
            }
            let recorded = try await ForceScene.run(world, frames: 240)
            ForceScene.assertHealthy(world, "q = \(q)")
            XCTAssertEqual(recorded.count, 240, "q = \(q)")
            let distances = recorded.compactMap { item in item.position(1).map { Double(wallX) - Double($0.x) } }
            guard distances.count == 240 else { XCTFail("q = \(q): brakuje klatek"); continue }
            let meanEpsilon = 1 - distances.reduce(0, +) / Double(distances.count) / Double(kind.radius)
            XCTAssertEqual(meanEpsilon, expected, accuracy: 1e-3 * expected, "q = \(q): ε z silnika \(meanEpsilon), z Double \(expected)")
        }
    }

    // MARK: P-B-6 (G2-AC3)

    /// W parze tego samego materiału wgniecenia dzielą się w proporcji r_a : r_b ± 2 %. Wgniecenie bańki to r − cięciwa jej konturu
    /// (odległość od środka do płaskiego odcinka przy kontakcie).
    func testSameMaterialPairSplitsTheDeflectionInProportionToTheRadii() async throws {
        let a = ForceScene.two, b = ForceScene.b7168, force: Float = 1200
        let dStar = Double(a.radius + b.radius) * (1 - ContactLawReference.epsilon(forForceRatio: Double(force) / stiffness))
        let half = Float(dStar / 2)
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [-half, 0], a)).add(ForceScene.bubble(2, at: [half, 0], b))
                .add(ForceScene.push(3, on: 1, force: [force, 0], around: .zero))
                .add(ForceScene.push(4, on: 2, force: [-force, 0], around: .zero))
        }
        let recorded = try await ForceScene.run(world, frames: 60)
        ForceScene.assertHealthy(world)
        let last = try XCTUnwrap(recorded.last)
        let pa = try XCTUnwrap(last.position(1)), pb = try XCTUnwrap(last.position(2))
        let snapshot = world.debugContourSnapshot()
        let contourA = try XCTUnwrap(snapshot[ForceScene.id(1)]), contourB = try XCTUnwrap(snapshot[ForceScene.id(2)])
        let normal = (pb - pa) / simd_distance(pa, pb)
        let deflectionA = Double(a.radius - ForceScene.chord(of: contourA, center: pa, toward: normal))
        let deflectionB = Double(b.radius - ForceScene.chord(of: contourB, center: pb, toward: normal * -1))
        XCTAssertGreaterThan(deflectionA, 0.1, "bańka a ma być wyraźnie wgnieciona")
        XCTAssertGreaterThan(deflectionB, 0.1, "bańka b ma być wyraźnie wgnieciona")
        XCTAssertEqual(deflectionA / deflectionB, Double(a.radius) / Double(b.radius), accuracy: 0.02 * Double(a.radius) / Double(b.radius),
                       "podział wgniecenia \(deflectionA) : \(deflectionB)")
    }

    /// W parze różnych K_a ≠ K_b siła z równania r_a ε(F/K_a) + r_b ε(F/K_b) = δ (Newton w silniku) zgadza się z Double ± 1 %. Równowaga pod
    /// siłą zewnętrzną F dowodzi tego bez dostępu do siły kontaktu: z odległości środków wynika nakładanie δ, a odniesienie daje z niego F.
    func testDifferentMaterialPairForceMatchesTheNewtonReferenceWithinOnePercent() async throws {
        let a = ForceScene.two, b = ForceScene.two
        for (force, ratio) in [(Float(1200), 10.0), (Float(1200), 1000.0), (Float(100), 10.0)] {
            let stiffnessB = stiffness * ratio
            let epsilonA = ContactLawReference.epsilon(forForceRatio: Double(force) / stiffness)
            let epsilonB = ContactLawReference.epsilon(forForceRatio: Double(force) / stiffnessB)
            let dStar = Double(a.radius) * (1 - epsilonA) + Double(b.radius) * (1 - epsilonB)
            let half = Float(dStar / 2)
            let world = try ForceScene.makeWorld(secondStiffness: Float(stiffnessB)) {
                try $0.add(ForceScene.bubble(1, at: [-half, 0], a))
                    .add(ForceScene.bubble(2, at: [half, 0], b, material: ForceScene.secondBubbleMaterial))
                    .add(ForceScene.push(3, on: 1, force: [force, 0], around: .zero))
                    .add(ForceScene.push(4, on: 2, force: [-force, 0], around: .zero))
            }
            let recorded = try await ForceScene.run(world, frames: 240)
            ForceScene.assertHealthy(world, "F = \(force), K_b / K_a = \(ratio)")
            XCTAssertEqual(recorded.count, 240)
            let distances = recorded.compactMap { item -> Double? in
                guard let pa = item.position(1), let pb = item.position(2) else { return nil }
                return Double(simd_distance(pa, pb))
            }
            guard distances.count == 240 else { XCTFail("brakuje klatek"); continue }
            let mean = distances.reduce(0, +) / Double(distances.count)
            let overlap = Double(a.radius + b.radius) - mean
            let contact = try XCTUnwrap(ContactLawReference.pairContact(
                overlap: overlap, a: .init(radius: Double(a.radius), stiffness: stiffness),
                b: .init(radius: Double(b.radius), stiffness: stiffnessB)))
            XCTAssertEqual(contact.force, Double(force), accuracy: 0.01 * Double(force),
                           "F = \(force), K_b / K_a = \(ratio): siła z nakładania \(overlap) wynosi \(contact.force)")
        }
    }
}
