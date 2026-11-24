import BubblePhysics
import XCTest

/// Sonda ugięcia w spoczynku (audyt testów spec. 4, zadanie 15): bańka dociśnięta `MotorDrive` do ściany ugina się według prawa kontaktu
/// ε / (1 − ε)² = F / K_c i stoi, niezależnie od masy i kroku stałego świata.
///
/// Dawna wersja mierzyła współczynnik 3,85 między ugięciem a c · F i prędkość spoczynkową w stronę ściany, bo `nativeUpdateVelocities`
/// dopisywało do prędkości tylko część korekty XPBD, i badała oś ζ_c. Silnik 4.0.0 liczy siły wprost z geometrii, więc ugięcie w równowadze
/// to rozwiązanie prawa (bez współczynnika solvera), a oś ζ_c znika razem z dashpotem kontaktu. Spoczynek wymaga oporu γ > 0: bez niego
/// bańka dociśnięta stałą siłą drga bez końca.
@MainActor
final class ContactVelocityCorrectionProbeTests: XCTestCase {
    private let force: Float = 300
    private let radius: Float = 20
    /// K_c = r_ref / c₀ = 20 / 0,01: q = F / K_c = 0,15, ε ≈ 0,10.
    private let compliance: Float = 0.01
    private let damping: Float = 5

    private struct Measurement {
        var epsilon: Float
        var restingSpeed: Float
        var positionDrift: Float
    }

    private func measure(mass: Float, dt: Double, seconds: Double = 5) async throws -> Measurement {
        let configuration = try WorldConfiguration(simulationRegion: CrowdScene.region(), fixedTimeStep: dt,
                                                   eventBufferCapacity: 4096)
        let world = try BubbleWorld(configuration: configuration)
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: compliance, damping: damping))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        setup = try CrowdScene.pressedBubble(setup, 1, y: 0, radius: radius, force: force, mass: mass)
        _ = world.submit(setup)
        _ = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "przygotowanie sceny")

        let steps = Int((seconds / dt).rounded())
        let window = Int((1 / dt).rounded())
        var depths: [Float] = [], positions: [Float] = []
        var speed: Float = .nan
        for index in 0..<steps {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index)")
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            if index >= steps - window {
                depths.append(CrowdScene.wallDepth(of: state, targetRadius: radius))
                positions.append(state.position.x)
            }
            speed = (state.velocity.x * state.velocity.x + state.velocity.y * state.velocity.y).squareRoot()
        }
        let depth = depths.reduce(0, +) / Float(depths.count)
        return Measurement(epsilon: depth / radius, restingSpeed: speed, positionDrift: (positions.max() ?? 0) - (positions.min() ?? 0))
    }

    func testDeflectionFollowsTheLawAndTheBubbleRestsForEveryMassAndStep() async throws {
        let expected = Float(ContactLawReference.epsilon(forForceRatio: Double(force) / Double(20 / compliance)))
        for (mass, dt) in [(Float(1), 1.0 / 60), (4, 1.0 / 60), (1, 1.0 / 120), (4, 1.0 / 120)] {
            let name = "m = \(mass), dt = 1/\(Int((1 / dt).rounded()))"
            let m = try await measure(mass: mass, dt: dt)
            XCTAssertEqual(m.epsilon, expected, accuracy: 0.02 * expected, "\(name): ε z prawa \(expected), zmierzone \(m.epsilon)")
            XCTAssertLessThan(m.restingSpeed, 0.1, "\(name): bańka w spoczynku publikuje prędkość")
            XCTAssertLessThan(m.positionDrift, 0.02 * radius, "\(name): bańka nie stoi")
        }
    }
}
