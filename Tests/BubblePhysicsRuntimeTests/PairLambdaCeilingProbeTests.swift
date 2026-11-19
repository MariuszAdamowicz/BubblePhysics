@testable import BubblePhysics
import Metal
import simd
import XCTest

/// Sonda sufitu siły pary miękkiej po zmianie z wycinka 1 planu v2.3.0 (pełna korekta XPBD w prędkości bańki miękkiej).
///
/// `nativePairLambdaLimit` ogranicza λ pary do (zbliżenie + 0,25 · min r) / max(m⁻¹), a zbliżenie liczy z prędkości przewidzianej,
/// która zawiera przyrost F · dt / m od siły zewnętrznej bańki. W spoczynku para musi przenieść λ = F · dt².
/// - Pchnięcie wprost: siła działa na lżejszą bańkę pary, więc zbliżenie F · dt² / m · m pokrywa całe λ i sufitu nie ma.
/// - Łańcuch: siła przechodzi przez bańkę środkową bez własnej siły. Para środkowa–sąsiadka ma zbliżenie ≈ 0, gdy bańki stoją,
///   więc siła ma sufit F_max = 0,25 · min r · m_min / dt² (r = 12, m = 0,36, dt = 1/60: ≈ 3 888).
/// Dziś bańka w spoczynku ma prędkość w stronę sąsiadki (`ContactVelocityCorrectionProbeTests`), która podnosi limit.
///
/// Scena: sąsiadka r = 20, m = 1 przy lewej ścianie; za nią mała bańka r = 12, m = 0,36; w łańcuchu za małą jeszcze pchacz
/// r = 20, m = 1. `MotorDrive` pcha w lewo siłą F ostatnią bańkę. Materiał c₀ = 1e-3, r_ref = 20, s = 1, kc = 0, więc nakładanie
/// pary mała–sąsiadka w równowadze to (c_small + c_big) · F. Kontrola: ten sam świat bez limitu λ pary.
///
/// Test działa tylko z `BUBBLE_PHYSICS_PAIR_CEILING_PROBE=1` i z pełną korektą w `nativeUpdateVelocities` (zmiana z wycinka 1
/// albo tymczasowa łatka `correctionScale = 1` dla `contact.x > 0`). Na kodzie sprzed wycinka 1 oczekiwania nie obowiązują.
@MainActor
final class PairLambdaCeilingProbeTests: XCTestCase {
    private let dt = 1.0 / 60
    private let smallRadius: Float = 12, smallMass: Float = 0.36
    private let bigRadius: Float = 20, bigMass: Float = 1
    private let base: Float = 1e-3
    private var pairCompliance: Float { base * smallRadius / 20 + base * bigRadius / 20 }
    private var ceiling: Float { 0.25 * min(smallRadius, bigRadius) * min(smallMass, bigMass) / Float(dt * dt) }

    private struct Measurement {
        var overlap: Float
        var drift: Float
        var smallSpeed: Float
    }

    private func measure(force: Float, pairLimit: Bool, chain: Bool, seconds: Double = 3) async throws -> Measurement {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: CrowdScene.configuration(), device: device,
                                                       solverIterationLimit: 8, pairCorrectionLimit: pairLimit)
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: base))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        let wallX = -CrowdScene.interiorHalfSize.x
        setup = setup
            .add(try CrowdScene.bubble(1, at: [wallX + bigRadius, 0], radius: bigRadius, mass: bigMass))
            .add(try CrowdScene.bubble(2, at: [wallX + 2 * bigRadius + smallRadius, 0], radius: smallRadius, mass: smallMass))
        if chain {
            setup = setup.add(try CrowdScene.bubble(3, at: [wallX + 3 * bigRadius + 2 * smallRadius, 0], radius: bigRadius, mass: bigMass))
        }
        setup = setup.setMotorDrive(CrowdScene.id(chain ? 3 : 2), drive: try MotorDrive(force: [-force, 0]))
        _ = world.submit(setup)
        _ = await world.advance(by: dt)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "przygotowanie sceny")

        let steps = Int((seconds / dt).rounded()), window = Int((1 / dt).rounded())
        var overlaps: [Float] = []
        var speed: Float = .nan
        for index in 0..<steps {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "F = \(force), krok \(index)")
            let big = try XCTUnwrap(frame.objects[CrowdScene.id(1)]), small = try XCTUnwrap(frame.objects[CrowdScene.id(2)])
            if index >= steps - window {
                overlaps.append(bigRadius + smallRadius - simd_distance(big.position, small.position))
            }
            speed = simd_length(small.velocity)
        }
        return Measurement(overlap: overlaps.last ?? .nan, drift: (overlaps.max() ?? 0) - (overlaps.min() ?? 0), smallSpeed: speed)
    }

    private var enabled: Bool { ProcessInfo.processInfo.environment["BUBBLE_PHYSICS_PAIR_CEILING_PROBE"] == "1" }
    private let forces: [Float] = [2_000, 3_500, 4_500, 6_000]

    private func run(chain: Bool) async throws -> (limited: [Float: Measurement], free: [Float: Measurement]) {
        var limited: [Float: Measurement] = [:], free: [Float: Measurement] = [:]
        for force in forces {
            limited[force] = try await measure(force: force, pairLimit: true, chain: chain)
            free[force] = try await measure(force: force, pairLimit: false, chain: chain)
            for (name, m) in [("z limitem", limited[force]!), ("bez limitu", free[force]!)] {
                print("[pair-ceiling-probe] \(chain ? "łańcuch" : "wprost") F = \(force) \(name): nakładanie = \(m.overlap)"
                      + " (równowaga \(pairCompliance * force)), dryf w ostatniej sekundzie = \(m.drift), |v| małej = \(m.smallSpeed)")
            }
        }
        // Kontrola bez limitu: każda siła ma równowagę (c_small + c_big) · F.
        for (force, m) in free {
            XCTAssertEqual(m.overlap, pairCompliance * force, accuracy: 0.1 * pairCompliance * force, "bez limitu, F = \(force)")
            XCTAssertLessThan(m.drift, 0.5, "bez limitu, F = \(force): para stoi (łańcuch trzech mas uspokaja się wolniej)")
        }
        return (limited, free)
    }

    func testDirectPushOnTheLighterBubbleHasNoCeilingBecauseApproachCoversTheForce() async throws {
        try XCTSkipUnless(enabled, "sonda wymaga pełnej korekty XPBD w prędkości i BUBBLE_PHYSICS_PAIR_CEILING_PROBE=1")
        let (limited, _) = try await run(chain: false)
        for (force, m) in limited {
            XCTAssertEqual(m.overlap, pairCompliance * force, accuracy: 0.1 * pairCompliance * force, "wprost, F = \(force)")
        }
    }

    func testChainThroughAMiddleBubbleHasCeilingFromPairLambdaLimit() async throws {
        try XCTSkipUnless(enabled, "sonda wymaga pełnej korekty XPBD w prędkości i BUBBLE_PHYSICS_PAIR_CEILING_PROBE=1")
        print("[pair-ceiling-probe] sufit z modelu F_max = \(ceiling), c_pary = \(pairCompliance)")
        let (limited, _) = try await run(chain: true)
        for force in forces where force < ceiling {
            let m = try XCTUnwrap(limited[force])
            XCTAssertEqual(m.overlap, pairCompliance * force, accuracy: 0.1 * pairCompliance * force, "łańcuch, F = \(force) < sufit")
        }
        for force in forces where force > ceiling {
            let m = try XCTUnwrap(limited[force])
            XCTAssertGreaterThan(m.overlap, 1.5 * pairCompliance * force, "łańcuch, F = \(force) > sufit: przenikanie ponad równowagę")
        }
    }
}
