import BubblePhysics
import XCTest

/// P-B-19 (G4-AC5, CD-D-16): bańka z podatnością dociśnięta `MotorDrive` do ściany ugina się o c · F i stoi.
///
/// Dawna wersja tej sondy (commit 599276a) zmierzyła współczynnik k = 3,85 (dt = 1/60) i 7,57 (dt = 1/120) między ugięciem
/// a c · F oraz prędkość spoczynkową 14,3 jedn./s w stronę ściany. Przyczyną było `nativeUpdateVelocities`, które dopisywało
/// do prędkości tylko s = min(1, contactStiffness · dt²) korekty XPBD. Po zmianie bańka miękka dostaje pełną korektę kontaktów
/// XPBD, więc:
/// - ugięcie w równowadze to c · F, niezależnie od masy, kroku i tłumienia ζ_c (zmierzony stan ustalony nie zależy od dashpotu);
/// - opublikowana prędkość spoczynkowa jest zerem.
/// Warunki G4-AC5: podatność liniowa c₀·r/r_ref, `damping` materiału = 0, restytucja 0, prędkości poniżej `restSpeed`.
@MainActor
final class ContactVelocityCorrectionProbeTests: XCTestCase {
    private let force: Float = 300
    private let radius: Float = 20
    /// c₀ = 1e-3 przy r_ref = 20 i r = 20: c = c₀·r/r_ref = 1e-3.
    private let compliance: Float = 1e-3

    private struct Measurement {
        var depth: Float
        var restingSpeed: Float
        var positionDrift: Float
    }

    private func measure(mass: Float, dt: Double, dampingRatio: Float, seconds: Double = 5) async throws -> Measurement {
        let configuration = try WorldConfiguration(simulationRegion: CrowdScene.region(), fixedTimeStep: dt,
                                                   eventBufferCapacity: 4096)
        let world = try BubbleWorld(configuration: configuration)
        var setup = try CrowdScene.resources(
            bubble: CrowdScene.softBubblePhysics(base: compliance, dampingRatio: dampingRatio))
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
        return Measurement(depth: depths.reduce(0, +) / Float(depths.count), restingSpeed: speed,
                           positionDrift: (positions.max() ?? 0) - (positions.min() ?? 0))
    }

    func testSoftContactDeflectsByComplianceTimesForceAndRestsForEveryMassStepAndDampingRatio() async throws {
        let expected = compliance * force
        for (mass, dt) in [(Float(1), 1.0 / 60), (4, 1.0 / 60), (1, 1.0 / 120), (4, 1.0 / 120)] {
            var depths: [Float: Float] = [:]
            for ratio: Float in [0.2, 1] {
                let name = "m = \(mass), dt = 1/\(Int((1 / dt).rounded())), ζ_c = \(ratio)"
                let m = try await measure(mass: mass, dt: dt, dampingRatio: ratio)
                print("[contact-correction] \(name): ugięcie = \(m.depth) (c·F = \(expected)), |v| = \(m.restingSpeed),"
                      + " dryf w ostatniej sekundzie = \(m.positionDrift)")
                XCTAssertEqual(m.depth, expected, accuracy: 0.1 * expected, "\(name): ugięcie = c · F")
                XCTAssertLessThan(m.restingSpeed, 0.1, "\(name): bańka w spoczynku publikuje prędkość")
                XCTAssertLessThan(m.positionDrift, 0.02 * radius, "\(name): bańka nie stoi")
                depths[ratio] = m.depth
            }
            let low = try XCTUnwrap(depths[0.2]), high = try XCTUnwrap(depths[1])
            XCTAssertLessThan(abs(low - high), 0.1 * expected,
                              "m = \(mass), dt = \(dt): ugięcie statyczne nie zależy od ζ_c")
        }
    }
}
