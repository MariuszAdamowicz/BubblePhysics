import BubblePhysics
import XCTest

/// Bańka dociśnięta do ściany siłą większą niż K_c (audyt testów spec. 4; dawna poprawka 3.0.2, BF-D-1 – BF-D-3, BF-D-5). Strojenie jak w grze:
/// K_c = r_ref / c₀ = 20 / 0,0108 ≈ 1852, γ 5, gumka K_band 30, F_max = F, cel 2000 j za ścianą (naciąg ≈ 55 000 ≥ F). W prawie kontaktu F = K_c · ε / (1 − ε)² siła
/// rośnie bez granic, zanim środek dojdzie do ściany, więc w spoczynku ε* < 1 także dla F ≫ K_c (przy F 2222 ε* ≈ 0,5, nie 1,2 jak w
/// `v3.0.2`), środek nigdy nie dochodzi do krawędzi, a krok nie jest odrzucany ani nie kończy świata. Krawędź wejścia, strażnik środka
/// i margines za tylną krawędzią cienkiej ściany zniknęły razem z liniowym kontaktem.
@MainActor
final class DeepSqueezeWallTests: XCTestCase {
    private let stiffness: Float = 20 / 0.0108

    private func policy(force: Float) throws -> BubbleDrivePolicy {
        try BubbleDrivePolicy(bandStiffness: 30, maximumForce: force)
    }

    private func material() throws -> PhysicsMaterial {
        try CrowdScene.softBubblePhysics(base: 0.0108, referenceRadius: 20, damping: 5)
    }

    /// ε* z prawa kontaktu (odniesienie w Double): ε / (1 − ε)² = F / K_c.
    private func equilibrium(force: Float) -> Float {
        Float(ContactLawReference.epsilon(forForceRatio: Double(force) / Double(stiffness)))
    }

    /// Krok bez odrzucenia, bez `worldFailed` i bez przyczyny strażnika.
    private func advance(_ world: BubbleWorld, step: Int, label: String) async throws -> WorldFrame {
        let frame = await world.advance(by: CrowdScene.step)
        let diagnostics = world.diagnostics
        XCTAssertNil(diagnostics.lastAdvanceIssue, "\(label), krok \(step): \(String(describing: diagnostics.lastRejectionReason))")
        XCTAssertNil(diagnostics.failureReason, "\(label), krok \(step)")
        XCTAssertNil(diagnostics.lastSolverGuardCause, "\(label), krok \(step)")
        return frame
    }

    /// Bańka r startuje 20 od lewej ściany `CrowdScene` (T 48) i gumka ciągnie ją siłą F w ścianę przez `seconds` s; zwraca ε = wgniecenie / r
    /// po ostatnim kroku i największe ε z całego przebiegu.
    private func settle(radius: Float, force: Float, seconds: Double) async throws -> (final: Float, peak: Float) {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: material())
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        let start = WorldPoint(-CrowdScene.interiorHalfSize.x + radius + 20, 0)
        _ = world.submit(try setup.add(CrowdScene.bubble(1, at: start, radius: radius, drivePolicy: policy(force: force)))
            .beginPlayerDrive(CrowdScene.id(1), target: WorldPoint(-2000, 0)))
        var ratio: Float = 0, peak: Float = 0
        for step in 0..<Int(seconds * 60) {
            let frame = try await advance(world, step: step, label: "r \(radius), F \(force)")
            if world.diagnostics.lastAdvanceIssue != nil { break }
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)], "r \(radius), krok \(step): bańka zniknęła")
            ratio = CrowdScene.wallDepth(of: state, targetRadius: radius) / radius
            peak = max(peak, ratio)
        }
        return (ratio, peak)
    }

    /// F 2222 > K_c = 1852: bańka r 24 i r 74 staje w ε* z prawa kontaktu (± 2 %), środkiem przed krawędzią ściany (ε < 1 w każdym kroku),
    /// bez odrzuconego kroku, bez `worldFailed` i bez przyczyny strażnika. Bańka r 74 (m ≈ 13,7) osiada wolno, w czasie rzędu 10 s, więc
    /// przebieg trwa 60 s symulacji.
    func testBubblePressedHarderThanKcSettlesBeforeTheEdgeAtTheContactLawDeflection() async throws {
        let force: Float = 2222
        let expected = equilibrium(force: force)
        XCTAssertLessThan(expected, 1, "odniesienie: ε* z prawa kontaktu")
        for (radius, seconds) in [(Float(24), 6.0), (74, 60)] {
            let result = try await settle(radius: radius, force: force, seconds: seconds)
            XCTAssertEqual(result.final, expected, accuracy: 0.02 * expected, "r \(radius): końcowe ε")
            XCTAssertLessThan(result.peak, 1, "r \(radius): środek doszedł do krawędzi ściany")
        }
    }

    /// Siła ok. 11 i 27 razy większa niż K_c (F = 20 000 i 50 000): ε* rośnie ku 1 (0,74 i 0,83), ale środek zostaje przed krawędzią,
    /// a ugięcie zgadza się z prawem (± 2 % ε*), bez `worldFailed`. F nie przekracza naciągu gumki K_band · odległość celu ≈ 55 000.
    func testPressureFarAboveKcStillStopsBeforeTheEdge() async throws {
        for force: Float in [20_000, 50_000] {
            let expected = equilibrium(force: force)
            let result = try await settle(radius: 24, force: force, seconds: 6)
            XCTAssertEqual(result.final, expected, accuracy: 0.02 * expected, "F \(force): końcowe ε")
            XCTAssertLessThan(result.peak, 1, "F \(force): środek doszedł do krawędzi ściany")
        }
    }
}
