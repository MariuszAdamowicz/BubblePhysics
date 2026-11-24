import BubblePhysics
import XCTest

/// Szybkie uderzenie małej bańki dociśniętej gumką w ścianę (audyt testów spec. 4; dawna poprawka 3.0.1, BF-D-1, BF-D-2). Strojenie jak w grze:
/// K_c = r_ref / c₀ = 20 / 0,0108 ≈ 1852, γ 5, gumka K_band 30 i F_max 1200, cel daleko w ścianie lewej ramy `CrowdScene` (T 48).
/// W spoczynku ε* z prawa kontaktu ε / (1 − ε)² = F_max / K_c (ε* ≈ 0,34). Bańka r 24 startująca 150 od ściany uderza z ponad 100 j/s;
/// w `v3.0.0` przewidziany środek mijał krawędź i bańka stała na stałe w ε ≈ 1. W prawie z granicą na promieniu środek nigdy nie
/// dochodzi do krawędzi, więc uderzenie nie ma przestrzału, a bańka osiada w ε*.
@MainActor
final class WallImpactTests: XCTestCase {
    private let radius: Float = 24
    private let stiffness: Float = 20 / 0.0108
    private let maximumForce: Float = 1200

    private struct Outcome {
        var peak: Float = -.infinity
        var final: Float = 0
        /// Kroki, po których środek bańki był na krawędzi ściany albo za nią (ε ≥ 1).
        var stepsWithCenterBehindEdge: [Int] = []
        /// Największa prędkość normalna (w stronę ściany) w krokach bez kontaktu, z którą bańka wchodzi w kontakt.
        var impactSpeed: Float = 0
    }

    /// Bańka r 24 startuje `gap` od ściany, gumka ciągnie ją w ścianę przez `seconds` s; ε = wgniecenie / r po każdym kroku.
    private func run(gap: Float = 150, seconds: Double = 6) async throws -> Outcome {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: 0.0108, referenceRadius: 20, damping: 5))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        let policy = try BubbleDrivePolicy(bandStiffness: 30, maximumForce: maximumForce)
        let start = WorldPoint(-CrowdScene.interiorHalfSize.x + radius + gap, 0)
        _ = world.submit(try setup.add(CrowdScene.bubble(1, at: start, radius: radius, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: WorldPoint(-2000, 0)))
        var outcome = Outcome()
        for step in 0..<Int(seconds * 60) {
            let frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
            XCTAssertNil(world.diagnostics.failureReason)
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            let ratio = CrowdScene.wallDepth(of: state, targetRadius: radius) / radius
            outcome.peak = max(outcome.peak, ratio)
            outcome.final = ratio
            if ratio >= 1 { outcome.stepsWithCenterBehindEdge.append(step) }
            if ratio <= 0 { outcome.impactSpeed = max(outcome.impactSpeed, -state.velocity.x) }
        }
        return outcome
    }

    /// Szybkie uderzenie jest tłumione, bańka osiada w ε* z prawa kontaktu bez przestrzału, a środek ani razu nie kończy kroku na krawędzi
    /// ściany ani za nią; szczyt ε jest nad ε* (uderzenie wgniata głębiej niż spoczynek), ale poniżej 1.
    func testFastSmallBubbleSettlesAtTheContactLawDeflectionWithoutCrossingTheEdge() async throws {
        let outcome = try await run()
        let expected = Float(ContactLawReference.epsilon(forForceRatio: Double(maximumForce) / Double(stiffness)))
        // Warunek wstępny: uderzenie jest szybkie (dawny próg max(40, 2r) dashpotu).
        XCTAssertGreaterThan(outcome.impactSpeed, max(40, 2 * radius), "prędkość normalna tuż przed kontaktem")
        XCTAssertEqual(outcome.final, expected, accuracy: 0.02 * expected, "końcowe ε")
        XCTAssertGreaterThan(outcome.peak, expected, "uderzenie wgniata głębiej niż spoczynek")
        XCTAssertLessThan(outcome.peak, 1, "szczyt ε")
        XCTAssertEqual(outcome.stepsWithCenterBehindEdge, [], "kroki ze środkiem na krawędzi albo za nią")
    }
}
