import BubblePhysics
import XCTest

/// Sonda przyczyny współczynnika ≈ 3,85 między wgnieceniem w równowadze a c · F (nagłówek `ContactComplianceTests`).
///
/// Hipoteza: `nativeUpdateVelocities` dopisuje do prędkości tylko ułamek s = min(1, contactStiffness · dt²) korekty XPBD
/// (120 / 3600 ≈ 3,3 % przy dt = 1/60), a resztę prędkości w stronę ściany gasi tylko tłumik kontaktu f = 1 − e^(−16 · dt).
/// Wtedy w równowadze δ = k · c · F, gdzie k = 1 / (1 − (1 − s) · e^(−16 · dt)), a bańka stoi w miejscu
/// z opublikowaną prędkością (k − 1) · F · dt / m w stronę ściany. Przewidywania:
/// - k nie zależy od masy (3,85 przy m = 1 i m = 4, dt = 1/60);
/// - k rośnie przy mniejszym kroku (7,57 przy dt = 1/120). Hipoteza „8 iteracji Jacobiego nie domyka α” przewiduje odwrotnie:
///   mniejszy krok zwiększa α = c / dt² względem odwrotności masy, więc k powinno spadać do 1;
/// - prędkość w spoczynku nie jest zerowa: 14,3 jedn./s (m = 1, dt = 1/60), 3,6 (m = 4), 16,4 (m = 1, dt = 1/120).
@MainActor
final class ContactVelocityCorrectionProbeTests: XCTestCase {
    private let force: Float = 300
    private let radius: Float = 20
    /// c₀ = 1e-3 przy r_ref = 20 i r = 20, s = 1, k = 0: c = 1e-3.
    private let compliance: Float = 1e-3

    private struct Measurement {
        var factor: Float
        var restingVelocity: Float
        var positionDrift: Float
    }

    private func predictedFactor(dt: Double) -> Float {
        let s = min(1, 120 * dt * dt)
        return Float(1 / (1 - (1 - s) * exp(-16 * dt)))
    }

    private func measure(mass: Float, dt: Double, seconds: Double = 4) async throws -> Measurement {
        let configuration = try WorldConfiguration(simulationRegion: CrowdScene.region(), fixedTimeStep: dt,
                                                   eventBufferCapacity: 4096)
        let world = try BubbleWorld(configuration: configuration)
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: compliance))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        setup = try CrowdScene.pressedBubble(setup, 1, y: 0, radius: radius, force: force, mass: mass)
        _ = world.submit(setup)
        _ = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "przygotowanie sceny")

        let steps = Int((seconds / dt).rounded())
        let window = Int((1 / dt).rounded())
        var depths: [Float] = [], positions: [Float] = []
        var velocity: Float = .nan
        for index in 0..<steps {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index)")
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            if index >= steps - window {
                depths.append(CrowdScene.wallDepth(of: state, targetRadius: radius))
                positions.append(state.position.x)
            }
            velocity = state.velocity.x
        }
        let depth = depths.reduce(0, +) / Float(depths.count)
        return Measurement(factor: depth / (compliance * force),
                           restingVelocity: -velocity,
                           positionDrift: (positions.max() ?? 0) - (positions.min() ?? 0))
    }

    private func report(_ name: String, _ m: Measurement, predictedFactor: Float, predictedVelocity: Float) {
        print("[correctionScale-probe] \(name): k = \(m.factor) (model \(predictedFactor)), v_spoczynku = \(m.restingVelocity)"
              + " (model \(predictedVelocity)), dryf pozycji w ostatniej sekundzie = \(m.positionDrift)")
    }

    func testEquilibriumFactorIsIndependentOfMassAndGrowsWithSmallerStepAsCorrectionScalePredicts() async throws {
        let k60 = predictedFactor(dt: 1.0 / 60), k120 = predictedFactor(dt: 1.0 / 120)
        let light = try await measure(mass: 1, dt: 1.0 / 60)
        let heavy = try await measure(mass: 4, dt: 1.0 / 60)
        let fine = try await measure(mass: 1, dt: 1.0 / 120)
        report("m = 1, dt = 1/60", light, predictedFactor: k60, predictedVelocity: (k60 - 1) * force / 60)
        report("m = 4, dt = 1/60", heavy, predictedFactor: k60, predictedVelocity: (k60 - 1) * force / 60 / 4)
        report("m = 1, dt = 1/120", fine, predictedFactor: k120, predictedVelocity: (k120 - 1) * force / 120)

        // Bańka stoi: wgniecenie jest równowagą, a nie przejściem.
        for (name, m) in [("m = 1", light), ("m = 4", heavy), ("dt = 1/120", fine)] {
            XCTAssertLessThan(m.positionDrift, 0.02 * radius, "\(name): bańka nie stoi")
        }
        // Współczynnik zgodny z modelem correctionScale, a nie 1 jak w XPBD.
        XCTAssertEqual(light.factor, k60, accuracy: 0.1 * k60, "m = 1, dt = 1/60")
        XCTAssertEqual(heavy.factor, k60, accuracy: 0.1 * k60, "m = 4: k nie zależy od masy")
        XCTAssertEqual(fine.factor, k120, accuracy: 0.1 * k120, "dt = 1/120: k rośnie przy mniejszym kroku")
        XCTAssertGreaterThan(fine.factor, 1.5 * light.factor, "mniejszy krok zwiększa k (wbrew hipotezie Jacobiego)")
        // Opublikowana prędkość w spoczynku nie jest zerowa i ma wartość z modelu.
        XCTAssertEqual(light.restingVelocity, (k60 - 1) * force / 60, accuracy: 0.15 * (k60 - 1) * force / 60, "v, m = 1")
        XCTAssertEqual(heavy.restingVelocity, (k60 - 1) * force / 240, accuracy: 0.15 * (k60 - 1) * force / 240, "v, m = 4")
        XCTAssertEqual(fine.restingVelocity, (k120 - 1) * force / 120, accuracy: 0.15 * (k120 - 1) * force / 120, "v, dt = 1/120")
    }
}
