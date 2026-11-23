@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest
import simd

/// Kontur rysowany cięciwą r · (1 − ε) (P-B-8; G2-AC5): w parze w kontakcie płaskie odcinki konturów obu baniek leżą na jednej prostej, a
/// kontury się nie przenikają. Cięciwę bańki mierzy się jako najdalszy punkt jej konturu w stronę drugiej bańki (przy kontakcie to płaski odcinek).
@MainActor
final class ContourChordTests: XCTestCase {
    private let stiffness = 229.0

    /// Para ściśnięta polami o równych i przeciwnych siłach F; po ustaleniu cięciwy obu konturów sumują się do odległości środków (różnica
    /// ≤ 1e-3 · R, bez przenikania), a każda leży w r · (1 − ε) z prawa kontaktu (ε z F / K danej bańki).
    private func assertChordsCoincide(_ a: ForceScene.Kind, _ b: ForceScene.Kind, stiffnessB: Float? = nil, force: Float, name: String) async throws {
        let kb = Double(stiffnessB ?? Float(stiffness))
        let epsilonA = ContactLawReference.epsilon(forForceRatio: Double(force) / stiffness)
        let epsilonB = ContactLawReference.epsilon(forForceRatio: Double(force) / kb)
        let rest = Double(a.radius) * (1 - epsilonA) + Double(b.radius) * (1 - epsilonB)
        let half = Float(rest / 2)
        let world = try ForceScene.makeWorld(secondStiffness: stiffnessB) {
            try $0.add(ForceScene.bubble(1, at: [-half, 0], a))
                .add(ForceScene.bubble(2, at: [half, 0], b, material: stiffnessB == nil ? ForceScene.bubbleMaterial : ForceScene.secondBubbleMaterial))
                .add(ForceScene.push(3, on: 1, force: [force, 0], around: .zero))
                .add(ForceScene.push(4, on: 2, force: [-force, 0], around: .zero))
        }
        let recorded = try await ForceScene.run(world, frames: 60)
        let context = "\(name), F = \(force)"
        ForceScene.assertHealthy(world, context)
        XCTAssertEqual(recorded.count, 60, context)
        let last = try XCTUnwrap(recorded.last)
        let pa = try XCTUnwrap(last.position(1)), pb = try XCTUnwrap(last.position(2))
        let snapshot = world.debugContourSnapshot()
        let contourA = try XCTUnwrap(snapshot[ForceScene.id(1)], context), contourB = try XCTUnwrap(snapshot[ForceScene.id(2)], context)
        let distance = Double(simd_distance(pa, pb))
        let normal = (pb - pa) / simd_distance(pa, pb)
        let chordA = Double(ForceScene.chord(of: contourA, center: pa, toward: normal))
        let chordB = Double(ForceScene.chord(of: contourB, center: pb, toward: normal * -1))
        let radii = Double(a.radius) + Double(b.radius)
        XCTAssertGreaterThan(Double(a.radius) - chordA, 0.05, "\(context): kontur a ma być wyraźnie ścięty")
        XCTAssertGreaterThan(Double(b.radius) - chordB, 0.05, "\(context): kontur b ma być wyraźnie ścięty")
        XCTAssertLessThanOrEqual(chordA + chordB - distance, 1e-3 * radii, "\(context): kontury się przenikają o \(chordA + chordB - distance)")
        XCTAssertEqual(chordA + chordB, distance, accuracy: 1e-3 * radii, "\(context): cięciwy \(chordA) i \(chordB) wobec odległości środków \(distance)")
        XCTAssertEqual(chordA, Double(a.radius) * (1 - epsilonA), accuracy: 2e-3 * radii, "\(context): cięciwa a wobec r · (1 − ε)")
        XCTAssertEqual(chordB, Double(b.radius) * (1 - epsilonB), accuracy: 2e-3 * radii, "\(context): cięciwa b wobec r · (1 − ε)")
    }

    func testChordsOfAPairOfBubblesTwoCoincide() async throws {
        for force: Float in [100, 1200] { try await assertChordsCoincide(ForceScene.two, ForceScene.two, force: force, name: "„2”–„2”") }
    }

    func testChordsOfBubbleTwoAndBubble7168Coincide() async throws {
        for force: Float in [100, 1200] { try await assertChordsCoincide(ForceScene.two, ForceScene.b7168, force: force, name: "„2”–7168") }
    }

    func testChordsOfADifferentMaterialPairCoincide() async throws {
        try await assertChordsCoincide(ForceScene.two, ForceScene.two, stiffnessB: 2290, force: 1200, name: "„2”–„2”, K_b = 10 · K_a")
    }
}
