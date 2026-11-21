import BubblePhysics
import simd
import XCTest

/// P-B-20, P-B-21, P-B-22 (G4-AC1, G4-AC2, CD-D-6): kontakt miękki drga jak oscylator tłumiony o ω = √(1 / (c · μ)) i ζ = ζ_c.
///
/// Warunki: podatność liniowa c₀·r/r_ref (sprężyna liniowa), `damping` materiału = 0, restytucja 0, wychylenie mniejsze niż ugięcie statyczne,
/// prędkości daleko poniżej `restSpeed` = max(40, 2r). Podatność dobrana tak, żeby ω · dt ≈ 0,02: XPBD z α = c / dt² to
/// niejawny Euler, który sam tłumi tempem ≈ ω · dt / 2 (ζ_num ≈ 0,01), więc przy większym ω · dt dekrement mierzyłby głównie krok.
/// Wychylenie startowe to połowa ugięcia statycznego, więc kontakt przez cały ruch jest aktywny.
///
/// Dekrement liczymy bez znajomości równowagi z kolejnych ekstremów e₀ (start), e₁, e₂, e₃: amplitudy A_k = A₀ · rᵏ,
/// (e_k − e_{k+1}) = A_k + A_{k+1}, więc (e₀ − e₁) / (e₂ − e₃) = r⁻², a dekrement logarytmiczny pełnego okresu to 2 · ln(1 / r)
/// = ln((e₀ − e₁) / (e₂ − e₃)).
@MainActor
final class ContactDynamicsTests: XCTestCase {
    private let dt = 1.0 / 120
    private let radius: Float = 20
    /// Siła ściskająca i ugięcie statyczne: c = c₀ · (r / r_ref)^1 = c₀ przy r = r_ref = 20.
    private let force: Float = 0.6
    private let compliance: Float = 0.174

    private var staticDeflection: Float { compliance * force }

    private func world(bubble: PhysicsMaterial, second: PhysicsMaterial? = nil) throws -> (BubbleWorld, WorldTransaction) {
        let configuration = try WorldConfiguration(simulationRegion: CrowdScene.region(), fixedTimeStep: dt,
                                                   eventBufferCapacity: 4096)
        var setup = try CrowdScene.resources(bubble: bubble)
        if let second { setup = setup.updatePhysicsMaterial(CrowdScene.secondBubbleMaterial, material: second) }
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        return (try BubbleWorld(configuration: configuration), setup)
    }

    /// Wgniecenie bańki ze ścianą po starcie w połowie ugięcia statycznego, bez prędkości. Bańkę dociska stała siła globalna
    /// (G4-AC1).
    private func wallSeries(dampingRatio: Float, seconds: Double) async throws -> [Float] {
        let material = try CrowdScene.softBubblePhysics(base: compliance, dampingRatio: dampingRatio)
        let (world, base) = try world(bubble: material)
        let start = staticDeflection / 2
        let position = WorldPoint(-(CrowdScene.interiorHalfSize.x - radius + start), 0)
        let setup = try base
            .add(CrowdScene.bubble(1, at: position, radius: radius, mass: 1))
            .setGlobalForce([-force, 0])
        _ = world.submit(setup)
        var series: [Float] = []
        for index in 0..<Int((seconds / dt).rounded()) {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index)")
            series.append(CrowdScene.wallDepth(of: try XCTUnwrap(frame.objects[CrowdScene.id(1)]), targetRadius: radius))
        }
        return series
    }

    /// Nakładanie pary (r_a + r_b − odległość środków) bańki 1 (m = 1, ζ_a) i 2 (m = 4, ζ_b) ściskanych ku sobie dwoma polami
    /// kierunkowymi o równych, przeciwnych siłach, każde z filtrem na ID jednej bańki.
    private func pairSeries(ratioA: Float, ratioB: Float, seconds: Double) async throws -> [Float] {
        let (world, base) = try world(bubble: CrowdScene.softBubblePhysics(base: compliance, dampingRatio: ratioA),
                                            second: CrowdScene.softBubblePhysics(base: compliance, dampingRatio: ratioB))
        // Połowa ugięcia statycznego pary: (c_a + c_b) · F / 2.
        let overlap = compliance * force
        let distance = 2 * radius - overlap
        func field(_ id: UInt64, target: UInt64, direction: Float) throws -> WorldObject {
            .forceField(try ForceFieldDescriptor(id: CrowdScene.id(id), position: .zero, geometry: RangeGeometry(shape: .circle(radius: 100)),
                field: .directional(force: [direction * force, 0]), filter: ObjectFilter(objectIDs: [CrowdScene.id(target)])))
        }
        let setup = try base
            .add(CrowdScene.bubble(1, at: [-distance / 2, 0], radius: radius, mass: 1))
            .add(CrowdScene.bubble(2, at: [distance / 2, 0], radius: radius, mass: 4, material: CrowdScene.secondBubbleMaterial))
            .add(field(500, target: 1, direction: 1))
            .add(field(501, target: 2, direction: -1))
        _ = world.submit(setup)
        var series: [Float] = []
        for index in 0..<Int((seconds / dt).rounded()) {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index)")
            let a = try XCTUnwrap(frame.objects[CrowdScene.id(1)]), b = try XCTUnwrap(frame.objects[CrowdScene.id(2)])
            series.append(2 * radius - simd_distance(a.position, b.position))
        }
        return series
    }

    /// Ekstrema szeregu: pierwsza próbka jako e₀, potem każda zmiana kierunku zmian (próbki bez zmiany nie liczą się jako kierunek,
    /// bo położenie Float przy ścianie ma krok ≈ 1,5e-5).
    private func extrema(_ series: [Float]) -> [Float] { extremumIndices(series).map { series[$0] } }

    /// Indeksy ekstremów (pierwsza próbka jako e₀), z których `extrema` bierze wartości.
    private func extremumIndices(_ series: [Float]) -> [Int] {
        var result: [Int] = [0]
        var direction: Float = 0
        for i in 1..<series.count {
            let change = series[i] - series[i - 1]
            guard change != 0 else { continue }
            let sign: Float = change > 0 ? 1 : -1
            if direction != 0, sign != direction { result.append(i - 1) }
            direction = sign
        }
        return result
    }

    /// Okres drgań tłumionych z rozstawu pierwszych czterech ekstremów: kolejne ekstrema dzieli pół okresu.
    private func measuredPeriod(_ series: [Float]) -> Double {
        let indices = extremumIndices(series)
        XCTAssertGreaterThanOrEqual(indices.count, 4, "za mało ekstremów: \(indices)")
        guard indices.count >= 4 else { return .nan }
        return 2 * Double(indices[3] - indices[0]) / 3 * dt
    }

    /// Okres tłumiony 2π / (ω · √(1 − ζ²)) dla ω = √(1 / (podatność · masa)).
    private func expectedPeriod(compliance: Float, mass: Float, ratio: Float) -> Double {
        let omega = Double(1 / (compliance * mass)).squareRoot()
        return 2 * .pi / (omega * Double(1 - ratio * ratio).squareRoot())
    }

    private func logarithmicDecrement(_ series: [Float]) throws -> Float {
        let e = extrema(series)
        XCTAssertGreaterThanOrEqual(e.count, 4, "za mało ekstremów: \(e)")
        guard e.count >= 4 else { return .nan }
        return log((e[0] - e[1]) / (e[2] - e[3]))
    }

    private func expectedDecrement(_ ratio: Float) -> Float { 2 * .pi * ratio / (1 - ratio * ratio).squareRoot() }

    /// Przecięcia równowagi, tylko te, po których szereg odchodzi od niej o ponad `margin`.
    private func crossings(_ series: [Float], around equilibrium: Float, margin: Float) -> Int {
        var count = 0
        var side = 0
        for value in series {
            let deviation = value - equilibrium
            guard abs(deviation) > margin else { continue }
            let current = deviation > 0 ? 1 : -1
            if side != 0, current != side { count += 1 }
            side = current
        }
        return count
    }

    // P-B-20, wariant ściany.
    func testWallContactOscillatesWithLogarithmicDecrementOfTheDampingRatio() async throws {
        let series = try await wallSeries(dampingRatio: 0.2, seconds: 6)
        let measured = try logarithmicDecrement(series)
        print("[contact-dynamics] ściana ζ_c = 0,2: dekrement = \(measured), oczekiwany = \(expectedDecrement(0.2)), ekstrema = \(extrema(series).prefix(5))")
        XCTAssertEqual(measured, expectedDecrement(0.2), accuracy: 0.1 * expectedDecrement(0.2))
        // ω = √(1 / (c · m)), m = 1: sprawdza podatność i masę efektywną, nie tylko tłumienie.
        let period = measuredPeriod(series), expected = expectedPeriod(compliance: compliance, mass: 1, ratio: 0.2)
        print("[contact-dynamics] ściana ζ_c = 0,2: okres = \(period), oczekiwany = \(expected)")
        XCTAssertEqual(period, expected, accuracy: 0.1 * expected)
    }

    func testWallContactWithCriticalDampingDoesNotOvershootTheEquilibrium() async throws {
        let series = try await wallSeries(dampingRatio: 1, seconds: 6)
        let peak = series.max() ?? 0
        print("[contact-dynamics] ściana ζ_c = 1: maksimum = \(peak), równowaga = \(staticDeflection), koniec = \(series.last ?? .nan)")
        XCTAssertLessThanOrEqual(peak, staticDeflection * 1.02, "przestrzelenie równowagi przy ζ_c = 1")
        XCTAssertEqual(series.last ?? .nan, staticDeflection, accuracy: 0.05 * staticDeflection, "dochodzi do równowagi")
    }

    // P-B-21, wariant pary: ω z masy zredukowanej, ζ_c średnie z obu materiałów.
    func testPairContactOscillatesWithAverageDampingRatioAndReducedMass() async throws {
        let series = try await pairSeries(ratioA: 0.1, ratioB: 0.3, seconds: 6)
        let measured = try logarithmicDecrement(series)
        print("[contact-dynamics] para ζ = (0,1; 0,3): dekrement = \(measured), oczekiwany = \(expectedDecrement(0.2))")
        XCTAssertEqual(measured, expectedDecrement(0.2), accuracy: 0.1 * expectedDecrement(0.2))
        // Podatność pary c_a + c_b = 2c, masa zredukowana 1 · 4 / (1 + 4).
        let period = measuredPeriod(series), expected = expectedPeriod(compliance: 2 * compliance, mass: 0.8, ratio: 0.2)
        print("[contact-dynamics] para: okres = \(period), oczekiwany = \(expected)")
        XCTAssertEqual(period, expected, accuracy: 0.1 * expected)
    }

    func testPairContactWithCriticalDampingDoesNotOvershootTheEquilibrium() async throws {
        let series = try await pairSeries(ratioA: 1, ratioB: 1, seconds: 6)
        let equilibrium = 2 * staticDeflection
        XCTAssertLessThanOrEqual(series.max() ?? 0, equilibrium * 1.02, "przestrzelenie równowagi pary przy ζ_c = 1")
    }

    // P-B-22
    func testUndampedSoftContactOvershootsTheEquilibriumAtLeastTwice() async throws {
        let series = try await wallSeries(dampingRatio: 0, seconds: 8)
        let overshoots = crossings(series, around: staticDeflection, margin: 0.1 * staticDeflection)
        print("[contact-dynamics] ściana ζ_c = 0: przecięcia równowagi = \(overshoots)")
        XCTAssertGreaterThanOrEqual(overshoots, 2)
    }
}
