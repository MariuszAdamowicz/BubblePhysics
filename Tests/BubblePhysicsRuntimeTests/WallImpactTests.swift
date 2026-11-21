import BubblePhysics
import XCTest

/// Szybkie uderzenie małej bańki dociśniętej gumką w ścianę (poprawka 3.0.1, BF-D-1, BF-D-2). Strojenie jak w grze: c₀ 0,0108,
/// r_ref 20, gumka K_band 30 i F_max 1200, cel daleko w ścianie lewej ramy `CrowdScene` (T 48). W spoczynku ε = c₀ · F / r_ref = 0,648.
/// W 3.0.0 bańka r 24 startująca 150 od ściany uderzała z ok. 173 j/s: dashpot ζ_c był pomijany powyżej max(40, 2r), a przewidziany
/// środek mijał krawędź, która wtedy przestawała odpychać, więc bańka stała na stałe w ε ≈ 1.
@MainActor
final class WallImpactTests: XCTestCase {
    private let radius: Float = 24
    /// ε w spoczynku: c₀ · F_max / r_ref.
    private let restingRatio: Float = 0.0108 * 1200 / 20

    private struct Outcome {
        var peak: Float = -.infinity
        var final: Float = 0
        /// Kroki, po których środek bańki był na krawędzi ściany albo za nią (ε ≥ 1).
        var stepsWithCenterBehindEdge: [Int] = []
    }

    /// Bańka r 24 startuje `gap` od ściany, gumka ciągnie ją w ścianę przez `seconds` s; ε = wgniecenie / r po każdym kroku.
    private func run(dampingRatio: Float, gap: Float = 150, seconds: Double = 6) async throws -> Outcome {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(
            base: 0.0108, referenceRadius: 20, damping: 5, dampingRatio: dampingRatio))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        let policy = try BubbleDrivePolicy(bandStiffness: 30, maximumForce: 1200)
        let start = WorldPoint(-CrowdScene.interiorHalfSize.x + radius + gap, 0)
        _ = world.submit(try setup.add(CrowdScene.bubble(1, at: start, radius: radius, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: WorldPoint(-2000, 0)))
        var outcome = Outcome()
        for step in 0..<Int(seconds * 60) {
            let frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            let ratio = CrowdScene.wallDepth(of: state, targetRadius: radius) / radius
            outcome.peak = max(outcome.peak, ratio)
            outcome.final = ratio
            if ratio >= 1 { outcome.stepsWithCenterBehindEdge.append(step) }
        }
        return outcome
    }

    /// (a) Z dashpotem ζ_c 5: szybkie uderzenie jest tłumione, bańka osiada w c · F bez przestrzału, a środek ani razu nie kończy
    /// kroku na krawędzi ściany.
    func testFastSmallBubbleSettlesAtComplianceTimesForceWithoutCrossingTheEdge() async throws {
        let outcome = try await run(dampingRatio: 5)
        XCTAssertEqual(outcome.final, restingRatio, accuracy: 0.02 * restingRatio, "końcowe ε")
        XCTAssertLessThan(outcome.peak, 1, "szczyt ε")
        XCTAssertEqual(outcome.stepsWithCenterBehindEdge, [], "kroki ze środkiem na krawędzi albo za nią")
    }

    /// (b) Bez dashpotu (ζ_c 0) przewidziany środek mija krawędź w kroku uderzenia; krawędź, przez którą wszedł, nadal go odpycha,
    /// więc bańka wraca i osiada w c · F zamiast stać w ε ≈ 1.
    func testBubbleWhosePredictedCenterPassesTheEdgeIsPushedBackByThatEdge() async throws {
        let outcome = try await run(dampingRatio: 0)
        XCTAssertEqual(outcome.final, restingRatio, accuracy: 0.02 * restingRatio, "końcowe ε")
    }
}
