@testable import BubblePhysics
import XCTest
import simd

/// Ugięcie konturu bańki w prawie kontaktu F = K_c · ε / (1 − ε)² (audyt testów spec. 4, zadanie 15): to samo względne ugięcie
/// ε dla każdego promienia, dwukrotna siła w prawie zamiast w ugięciu i podział wgniecenia pary w proporcji promieni. Oczekiwane ε
/// liczy `ContactLawReference` w Double, a ugięcie czytamy z pozycji i z promienia efektywnego (cięciwa r · (1 − ε)) opublikowanego w klatce.
///
/// Dla małych ε prawo daje F ≈ K_c · ε, więc dawna liniowość δ = c · F zostaje tylko jako przybliżenie: dla q = F / K_c = 0,5 ugięcie
/// to ε = 0,268, a nie 0,5. Bańki mają opór γ = 5, żeby po starcie z zetknięcia stanęły (bez oporu spoczynku w równowadze nie ma).
@MainActor
final class ContactComplianceTests: XCTestCase {
    private let stiffness: Float = 1200
    private let damping: Float = 5
    /// 10 s: opór γ = 5 tłumi amplitudę jak e^(−γ t / 2), więc po 10 s zostaje ułamek e^(−25).
    private let frames = 600

    private func expectedEpsilon(force: Float) -> Double {
        ContactLawReference.epsilon(forForceRatio: Double(force) / Double(stiffness))
    }

    /// Promień efektywny bańki z klatki (cięciwa konturu przy kontakcie).
    private func effectiveRadius(_ recorded: ForceScene.Recorded, _ value: UInt64) throws -> Double {
        let state = try XCTUnwrap(recorded.frame.objects[ForceScene.id(value)], "brak bańki \(value)")
        guard case .bubble(let radius) = state.kind else { XCTFail("obiekt \(value) nie jest bańką"); return 0 }
        return Double(radius)
    }

    // Ta sama siła ściska każdą bańkę o ten sam ułamek promienia, ε / (1 − ε)² = F / K_c, także gdy ε · r przekracza grubość ściany (r = 148).
    func testRelativeDeflectionIsTheSameForEveryRadius() async throws {
        let radii: [(id: UInt64, radius: Float, y: Float)] = [(1, 12, -700), (2, 24, -450), (3, 48, -250), (4, 148, 50)]
        let force: Float = 600
        let world = try ForceScene.makeWorld(damping: damping, stiffness: stiffness) { setup in
            try radii.reduce(setup.add(ForceScene.wall(10, x: 0)).setGlobalForce([force, 0])) { transaction, bubble in
                try transaction.add(ForceScene.bubble(bubble.id, at: [-bubble.radius, bubble.y],
                                                      .init(radius: bubble.radius, mass: 1)))
            }
        }
        let recorded = try await ForceScene.run(world, frames: frames)
        ForceScene.assertHealthy(world)
        let last = try XCTUnwrap(recorded.last)
        XCTAssertEqual(recorded.count, frames)
        let expected = expectedEpsilon(force: force)
        for bubble in radii {
            let x = try XCTUnwrap(last.position(bubble.id)).x
            let fromPosition = 1 - Double(-x) / Double(bubble.radius)
            let fromContour = 1 - (try effectiveRadius(last, bubble.id)) / Double(bubble.radius)
            XCTAssertEqual(fromPosition, expected, accuracy: 0.02 * expected, "r = \(bubble.radius): ε z położenia \(fromPosition), z prawa \(expected)")
            XCTAssertEqual(fromContour, expected, accuracy: 0.02 * expected, "r = \(bubble.radius): ε z konturu \(fromContour), z prawa \(expected)")
        }
    }

    // Podwojona siła podwaja F / K_c w prawie, a nie ugięcie: ε / (1 − ε)² rośnie dwukrotnie, a ε mniej niż dwukrotnie.
    func testDoubledForceDoublesTheLawRatioNotTheDeflection() async throws {
        let force: Float = 300
        let world = try ForceScene.makeWorld(damping: damping, stiffness: stiffness) { setup in
            try setup.add(ForceScene.wall(10, x: 0))
                .add(ForceScene.bubble(1, at: [-24, -300], ForceScene.two))
                .add(ForceScene.bubble(2, at: [-24, 300], ForceScene.two))
                .setMotorDrive(ForceScene.id(1), drive: MotorDrive(force: [force, 0]))
                .setMotorDrive(ForceScene.id(2), drive: MotorDrive(force: [2 * force, 0]))
        }
        let recorded = try await ForceScene.run(world, frames: frames)
        ForceScene.assertHealthy(world)
        let last = try XCTUnwrap(recorded.last)
        var epsilon: [Double] = []
        for (value, applied) in [(UInt64(1), force), (2, 2 * force)] {
            let measured = 1 - (try effectiveRadius(last, value)) / 24
            XCTAssertEqual(measured, expectedEpsilon(force: applied), accuracy: 0.02 * measured, "bańka \(value): ε z konturu \(measured)")
            epsilon.append(measured)
        }
        let law = { (e: Double) in e / ((1 - e) * (1 - e)) }
        XCTAssertEqual(law(epsilon[1]) / law(epsilon[0]), 2, accuracy: 0.06, "F / K_c rośnie dwukrotnie: ε \(epsilon[0]) → \(epsilon[1])")
        XCTAssertLessThan(epsilon[1], 2 * epsilon[0], "ugięcie rośnie wolniej niż siła")
    }

    // Para z jednego materiału ściskana dwoma polami wzdłuż osi: ε = δ / R z prawa z R = r_a + r_b, a wgniecenie konturu każdej bańki to ε · r.
    func testSoftPairOverlapFollowsTheLawAndDentsSplitByRadius() async throws {
        let force: Float = 600
        let epsilon = expectedEpsilon(force: force)
        for (radiusA, radiusB) in [(Float(12), Float(24)), (24, 24), (24, 148)] {
            let radii = Double(radiusA + radiusB)
            let distance = Float(radii * (1 - epsilon))
            let world = try ForceScene.makeWorld(damping: damping, stiffness: stiffness) { setup in
                try setup.add(ForceScene.bubble(1, at: [-distance / 2, 0], .init(radius: radiusA, mass: 1)))
                    .add(ForceScene.bubble(2, at: [distance / 2, 0], .init(radius: radiusB, mass: 1)))
                    .setMotorDrive(ForceScene.id(1), drive: MotorDrive(force: [force, 0]))
                    .setMotorDrive(ForceScene.id(2), drive: MotorDrive(force: [-force, 0]))
            }
            let recorded = try await ForceScene.run(world, frames: frames)
            ForceScene.assertHealthy(world, "(\(radiusA), \(radiusB))")
            let last = try XCTUnwrap(recorded.last)
            let first = try XCTUnwrap(last.position(1)), second = try XCTUnwrap(last.position(2))
            let measuredEpsilon = (radii - Double(simd_distance(first, second))) / radii
            XCTAssertEqual(measuredEpsilon, epsilon, accuracy: 0.02 * epsilon, "(\(radiusA), \(radiusB)): ε pary \(measuredEpsilon), z prawa \(epsilon)")
            let dentA = Double(radiusA) - (try effectiveRadius(last, 1)), dentB = Double(radiusB) - (try effectiveRadius(last, 2))
            XCTAssertEqual(dentA, epsilon * Double(radiusA), accuracy: 0.02 * epsilon * Double(radiusA), "(\(radiusA), \(radiusB)): wgniecenie a \(dentA)")
            XCTAssertEqual(dentB, epsilon * Double(radiusB), accuracy: 0.02 * epsilon * Double(radiusB), "(\(radiusA), \(radiusB)): wgniecenie b \(dentB)")
        }
    }
}
