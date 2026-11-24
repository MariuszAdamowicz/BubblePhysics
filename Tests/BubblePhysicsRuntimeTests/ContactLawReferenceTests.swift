import XCTest
import simd

/// Własne testy odniesienia w Double (`ContactLawReference`), z którego korzystają testy świata silnika 4.0.0
/// (`docs/sdlc/changes/2026-11-23-engine-4-0-0`, zadanie 1). Odniesienie nie zna silnika, więc tu sprawdza się je
/// niezależnie: tożsamościami analitycznymi, granicami i zachowawczym całkowaniem.
final class ContactLawReferenceTests: XCTestCase {
    private let stiffness = 229.0, radius = 24.0, step = 1.0 / 60

    // MARK: Prawo kontaktu

    func testForceLawMatchesDefinition() {
        // ε = 0,5: F = K · 0,5 / 0,25 = 2K.
        XCTAssertEqual(ContactLawReference.force(epsilon: 0.5, stiffness: stiffness), 2 * stiffness, accuracy: 1e-12)
        XCTAssertEqual(ContactLawReference.force(epsilon: 0, stiffness: stiffness), 0)
    }

    func testEpsilonInverseRoundTripsOverWholeRange() {
        for exponent in stride(from: -4.0, through: 6.0, by: 0.25) {
            let q = pow(10, exponent), epsilon = ContactLawReference.epsilon(forForceRatio: q)
            XCTAssertGreaterThan(epsilon, 0, "q = \(q)")
            XCTAssertLessThan(epsilon, 1, "q = \(q)")
            let back = epsilon / ((1 - epsilon) * (1 - epsilon))
            XCTAssertEqual(back, q, accuracy: q * 1e-9, "q = \(q)")
        }
    }

    func testEpsilonLimits() {
        // Mała siła: prawo jest prawie liniowe, ε ≈ q. Duża siła: 1 − ε ≈ 1 / √q.
        let small = ContactLawReference.epsilon(forForceRatio: 1e-4)
        XCTAssertEqual(small, 1e-4, accuracy: 1e-4 * 2e-4)
        let large = ContactLawReference.epsilon(forForceRatio: 1e6)
        XCTAssertEqual(1 - large, 1e-3, accuracy: 1e-3 * 2e-3)
    }

    func testEnergyIsTheIntegralOfForceOverDeflection() {
        // U(ε_max) = ∫₀^x F dx, x = r · ε; całka Simpsona z samej siły, niezależnie od wzoru zamkniętego.
        let epsilonMax = 0.6, panels = 20_000
        let h = epsilonMax / Double(panels)
        var sum = 0.0
        for i in 0...panels {
            let weight: Double = (i == 0 || i == panels) ? 1 : (i % 2 == 1 ? 4 : 2)
            sum += weight * ContactLawReference.force(epsilon: Double(i) * h, stiffness: stiffness)
        }
        let integral = sum * h / 3 * radius
        let energy = ContactLawReference.energy(epsilon: epsilonMax, stiffness: stiffness, radius: radius)
        XCTAssertEqual(energy, integral, accuracy: integral * 1e-9)
        // Przy małym ugięciu U ≈ ½ K r ε².
        let tiny = ContactLawReference.energy(epsilon: 1e-3, stiffness: stiffness, radius: radius)
        XCTAssertEqual(tiny, 0.5 * stiffness * radius * 1e-6, accuracy: 0.5 * stiffness * radius * 1e-6 * 2e-3)
    }

    func testEquilibriumDistanceBalancesTheForce() {
        for force in [1e2, 1200, 1e4, 2e4, 1e5] {
            let distance = ContactLawReference.equilibriumDistance(force: force, stiffness: stiffness, radius: radius)
            XCTAssertGreaterThan(distance, 0)
            XCTAssertLessThan(distance, radius)
            let epsilon = 1 - distance / radius
            XCTAssertEqual(ContactLawReference.force(epsilon: epsilon, stiffness: stiffness), force, accuracy: force * 1e-9)
        }
    }

    func testMaximumEpsilonSolvesEnergyBalance() {
        for speed in [1e2, 1e3, 3e3] {
            let kinetic = 0.5 * 1.0 * speed * speed
            let epsilon = ContactLawReference.maximumEpsilon(energy: kinetic, stiffness: stiffness, radius: radius)
            XCTAssertGreaterThan(epsilon, 0)
            XCTAssertLessThan(epsilon, 1)
            let energy = ContactLawReference.energy(epsilon: epsilon, stiffness: stiffness, radius: radius)
            XCTAssertEqual(energy, kinetic, accuracy: kinetic * 1e-9)
        }
        XCTAssertEqual(ContactLawReference.maximumEpsilon(energy: 0, stiffness: stiffness, radius: radius), 0)
    }

    // MARK: Para

    func testPairOfSameMaterialSplitsOverlapByRadius() throws {
        let ra = 24.0, rb = 148.0, overlap = 30.0
        let pair = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap,
            a: .init(radius: ra, stiffness: stiffness), b: .init(radius: rb, stiffness: stiffness)))
        XCTAssertEqual(pair.deflectionA + pair.deflectionB, overlap, accuracy: 1e-9)
        XCTAssertEqual(pair.deflectionA / pair.deflectionB, ra / rb, accuracy: 1e-9)
        XCTAssertEqual(pair.epsilonA, pair.epsilonB, accuracy: 1e-12)
    }

    func testPairOfDifferentMaterialsSatisfiesEquationAndForceEquality() throws {
        let overlap = 18.0
        for ratio in [1.0, 10, 1000] {
            let a = ContactLawReference.PairBody(radius: 24, stiffness: stiffness)
            let b = ContactLawReference.PairBody(radius: 148, stiffness: stiffness * ratio)
            let pair = try XCTUnwrap(ContactLawReference.pairContact(overlap: overlap, a: a, b: b))
            // r_a ε_a + r_b ε_b = δ
            XCTAssertEqual(a.radius * pair.epsilonA + b.radius * pair.epsilonB, overlap, accuracy: 1e-9)
            // Siła jest wspólna: F(ε_a; K_a) = F(ε_b; K_b) = F.
            let fa = ContactLawReference.force(epsilon: pair.epsilonA, stiffness: a.stiffness)
            let fb = ContactLawReference.force(epsilon: pair.epsilonB, stiffness: b.stiffness)
            XCTAssertEqual(fa, pair.force, accuracy: pair.force * 1e-9)
            XCTAssertEqual(fb, pair.force, accuracy: pair.force * 1e-9)
            if ratio > 1 { XCTAssertLessThan(pair.epsilonB, pair.epsilonA) }
        }
    }

    func testPairContactIsAbsentWithoutOverlapAndRejectsFullPenetration() {
        let a = ContactLawReference.PairBody(radius: 24, stiffness: stiffness)
        let b = ContactLawReference.PairBody(radius: 24, stiffness: stiffness)
        XCTAssertEqual(ContactLawReference.pairContact(overlap: 0, a: a, b: b)?.force, 0)
        XCTAssertNil(ContactLawReference.pairContact(overlap: 48, a: a, b: b), "δ = r_a + r_b to środki w jednym punkcie")
    }

    // MARK: Reguła h, symulacja 1D

    /// Bańka „2” lecąca w ścianę; start kilka klatek przed kontaktem.
    private func wall(speed: Double, damping: Double = 0, start: Double? = nil, press: Double = 0,
                      mass: Double = 1, maximumSubsteps: Int = 1024) -> ContactLawReference.WallScene {
        ContactLawReference.WallScene(radius: radius, mass: mass, stiffness: stiffness, damping: damping,
            startDistance: start ?? radius + speed * 0.05 + 2, velocity: -speed, pressForce: press,
            frameStep: step, maximumSubstepsPerFrame: maximumSubsteps)
    }

    func testFreeMotionAwayFromWallIsOneSubstepPerFrame() {
        // Bańka daleko od ściany i wolna: d / (4 |v|) ≥ dt.
        var scene = wall(speed: 0)
        scene.startDistance = 500; scene.velocity = 100
        let trace = scene.run(frames: 30)
        XCTAssertEqual(trace.frames.map(\.substeps), Array(repeating: 1, count: 30))
        XCTAssertEqual(trace.frames.last!.distance, 500 + 100 * 30 * step, accuracy: 1e-9)
    }

    func testStaticPressTakesThreeSubstepsAsInSpecification() {
        // G5-AC2: F = 20 000 przy K_c = 229, r = 24, m = 1 daje ω · dt ≈ 2,2, więc 3 ± 1 podkroki.
        let d = ContactLawReference.equilibriumDistance(force: 20_000, stiffness: stiffness, radius: radius)
        let trace = wall(speed: 0, start: d, press: 20_000).run(frames: 120)
        for frame in trace.frames { XCTAssertTrue((2...4).contains(frame.substeps), "\(frame.substeps)") }
        // Statyka: start w równowadze, więc d zostaje przy d* (G2-AC1: 0,5 % + 1e-3 j).
        for frame in trace.frames { XCTAssertEqual(frame.distance, d, accuracy: d * 0.005 + 1e-3) }
    }

    func testHeadOnImpactReflectsWithSameSpeedAndSubstepsRiseThenReturnToOne() throws {
        let speed = 1000.0
        let trace = wall(speed: speed).run(frames: 60)
        XCTAssertFalse(trace.limitExceeded)
        XCTAssertFalse(trace.penetrated)
        let counts = trace.frames.map(\.substeps)
        // Przed kontaktem i długo po nim jest 1 podkrok, w kontakcie wiele (ocena autora: rzędu 20 przy dojeździe i odjeździe).
        XCTAssertEqual(counts.first, 1)
        XCTAssertEqual(counts.last, 1)
        let peak = try XCTUnwrap(counts.max())
        XCTAssertTrue((10...60).contains(peak), "szczyt \(peak)")
        // Prędkość odbicia = prędkość uderzenia ± 2 % (G4-AC1, leapfrog zachowawczy).
        let final = try XCTUnwrap(trace.frames.last)
        XCTAssertEqual(final.velocity, speed, accuracy: speed * 0.02)
        // Najmniejsze d z bilansu energii: d = r (1 − ε_max), U(ε_max) = ½ m v².
        let epsilonMax = ContactLawReference.maximumEpsilon(energy: 0.5 * speed * speed, stiffness: stiffness, radius: radius)
        let expected = radius * (1 - epsilonMax)
        let dmin = try XCTUnwrap(trace.substeps.map(\.distance).min())
        XCTAssertEqual(dmin, expected, accuracy: expected * 0.1)
        XCTAssertGreaterThan(dmin, 0)
    }

    func testSubstepSizeFollowsTheRuleAtEverySubstep() {
        let trace = wall(speed: 1000).run(frames: 20)
        XCTAssertFalse(trace.substeps.isEmpty)
        for substep in trace.substeps {
            XCTAssertLessThanOrEqual(substep.h, substep.limit + 1e-15)
            XCTAssertLessThanOrEqual(substep.h, step + 1e-15)
            XCTAssertGreaterThan(substep.h, 0)
        }
        // Czasy podkroków w klatce sumują się do kroku.
        var start = 0
        for frame in trace.frames {
            let slice = trace.substeps[start ..< start + frame.substeps]
            XCTAssertEqual(slice.reduce(0) { $0 + $1.h }, step, accuracy: 1e-12)
            start += frame.substeps
        }
        XCTAssertEqual(start, trace.substeps.count)
    }

    func testDampedImpactEnergyLossEqualsDragWork() throws {
        // G4-AC2: ubytek (kinetyczna + sprężysta) = ∫ γ m |v|² dt z zapisu podkroków; tu tylko spójność odniesienia.
        for (gamma, speed) in [(1.0, 100.0), (5.0, 100.0), (1.0, 1000.0), (5.0, 1000.0)] {
            let scene = wall(speed: speed, damping: gamma)
            let trace = scene.run(frames: 180)
            XCTAssertFalse(trace.limitExceeded)
            let initial = scene.energy(distance: scene.startDistance, velocity: scene.velocity)
            let last = try XCTUnwrap(trace.frames.last)
            let finalEnergy = scene.energy(distance: last.distance, velocity: last.velocity)
            let drag = trace.substeps.reduce(0) { $0 + gamma * scene.mass * $1.midVelocity * $1.midVelocity * $1.h }
            XCTAssertGreaterThan(drag, 0)
            XCTAssertEqual(initial - finalEnergy, drag, accuracy: drag * 0.05 + initial * 0.01, "γ \(gamma), v \(speed)")
        }
    }

    func testSubstepLimitIsReportedAndStopsTheFrame() {
        let trace = wall(speed: 1000, maximumSubsteps: 5).run(frames: 60)
        XCTAssertTrue(trace.limitExceeded)
        XCTAssertLessThanOrEqual(trace.frames.map(\.substeps).max() ?? 0, 5)
    }

    func testBandStiffnessRaisesOmegaAndSubstepCount() {
        // Dodatkowa sztywność (gumka) wchodzi do ω: K_band = 22 nadal daje jeden podkrok, K_band = 2·10⁴ już kilka.
        var scene = wall(speed: 0)
        scene.startDistance = 500; scene.velocity = 0
        scene.bandStiffness = 22
        XCTAssertEqual(scene.run(frames: 5).frames.map(\.substeps), Array(repeating: 1, count: 5))
        scene.bandStiffness = 20_000
        XCTAssertGreaterThan(scene.run(frames: 5).frames.first!.substeps, 2)
    }

    // MARK: Pole radialne

    func testRadialFieldTrajectoryConservesEnergyAndAngularMomentum() {
        // Stała siła przyciągająca 500 ku środkowi pola: potencjał 500 · |x| (w zasięgu pola).
        let field = ContactLawReference.RadialField(strength: -500, falloff: 0, radius: 400)
        let start = SIMD2<Double>(100, 0), velocity = SIMD2<Double>(0, 100)
        let end = ContactLawReference.integrateRadialField(field, mass: 1, damping: 0, position: start, velocity: velocity,
                                                          duration: 2, step: 1e-4)
        func energy(_ p: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { 0.5 * simd_length_squared(v) + 500 * simd_length(p) }
        func angular(_ p: SIMD2<Double>, _ v: SIMD2<Double>) -> Double { p.x * v.y - p.y * v.x }
        XCTAssertEqual(energy(end.position, end.velocity), energy(start, velocity), accuracy: energy(start, velocity) * 1e-8)
        XCTAssertEqual(angular(end.position, end.velocity), angular(start, velocity), accuracy: abs(angular(start, velocity)) * 1e-8)
        XCTAssertGreaterThan(simd_length(end.position - start), 1)
    }

    func testRadialFieldTrajectoryConvergesWithStep() {
        let field = ContactLawReference.RadialField(strength: -500, falloff: 0, radius: 400)
        let coarse = ContactLawReference.integrateRadialField(field, mass: 1, damping: 0, position: [100, 0], velocity: [0, 100], duration: 2, step: 1e-4)
        let fine = ContactLawReference.integrateRadialField(field, mass: 1, damping: 0, position: [100, 0], velocity: [0, 100], duration: 2, step: 5e-5)
        XCTAssertLessThan(simd_length(coarse.position - fine.position), 1e-6)
    }

    func testRadialFieldFalloffAndRangeFollowTheEngineFormula() {
        // Siła = strength · (1 − d/R)^falloff w kierunku od środka (ujemna strength przyciąga), poza zasięgiem zero.
        let field = ContactLawReference.RadialField(strength: -500, falloff: 2, radius: 400)
        let inside = field.force(at: [200, 0])
        XCTAssertEqual(inside.x, -500 * 0.25, accuracy: 1e-12)
        XCTAssertEqual(inside.y, 0, accuracy: 1e-12)
        XCTAssertEqual(field.force(at: [401, 0]), .zero)
        XCTAssertEqual(field.force(at: .zero), .zero)
        // falloff = 0 to stała siła.
        let flat = ContactLawReference.RadialField(strength: -500, falloff: 0, radius: 400)
        XCTAssertEqual(simd_length(flat.force(at: [399, 0])), 500, accuracy: 1e-12)
    }
}
