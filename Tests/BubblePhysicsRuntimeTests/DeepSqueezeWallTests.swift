import BubblePhysics
import XCTest

/// Bańka dociśnięta do ściany siłą F > r_ref / c₀ (poprawka 3.0.2, BF-D-1 – BF-D-3, BF-D-5). Strojenie jak w grze: c₀ 0,0108, r_ref 20,
/// ζ_c 5, gumka K_band 30, F_max = F, cel daleko w ścianie. Krawędź wejścia odpycha liniowo, więc w spoczynku ε = c₀ · F / r_ref także
/// dla ε > 1: przy F 2222 ε = 1,2, środek za krawędzią. W 3.0.1 strażnik środka cofał środek na krawędź − margines (ε ≈ 0,9999),
/// a środek dokładnie na krawędzi odrzucał krok (`SolverGuardCause.centerCrossing`) w pętli aż do `stepsRejected`.
@MainActor
final class DeepSqueezeWallTests: XCTestCase {
    private let baseCompliance: Float = 0.0108
    private let referenceRadius: Float = 20

    private func policy(force: Float) throws -> BubbleDrivePolicy {
        try BubbleDrivePolicy(bandStiffness: 30, maximumForce: force)
    }

    private func material() throws -> PhysicsMaterial {
        try CrowdScene.softBubblePhysics(base: baseCompliance, referenceRadius: referenceRadius, damping: 5, dampingRatio: 5)
    }

    /// Krok bez odrzucenia i bez przyczyny strażnika.
    private func advance(_ world: BubbleWorld, step: Int, label: String) async throws -> WorldFrame {
        let frame = await world.advance(by: CrowdScene.step)
        let diagnostics = world.diagnostics
        XCTAssertNil(diagnostics.lastAdvanceIssue, "\(label), krok \(step): \(String(describing: diagnostics.lastRejectionReason))")
        XCTAssertNil(diagnostics.lastSolverGuardCause, "\(label), krok \(step)")
        return frame
    }

    /// Bańka r startuje 20 od lewej ściany `CrowdScene` (T 48) i gumka ciągnie ją siłą F w ścianę przez `seconds` s; ε = wgniecenie / r
    /// po ostatnim kroku.
    private func settle(radius: Float, force: Float, seconds: Double) async throws -> Float {
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: material())
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        let start = WorldPoint(-CrowdScene.interiorHalfSize.x + radius + 20, 0)
        _ = world.submit(try setup.add(CrowdScene.bubble(1, at: start, radius: radius, drivePolicy: policy(force: force)))
            .beginPlayerDrive(CrowdScene.id(1), target: WorldPoint(-2000, 0)))
        var ratio: Float = 0
        for step in 0..<Int(seconds * 60) {
            let frame = try await advance(world, step: step, label: "r \(radius)")
            if world.diagnostics.lastAdvanceIssue != nil { break }
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)], "r \(radius), krok \(step): bańka zniknęła")
            ratio = CrowdScene.wallDepth(of: state, targetRadius: radius) / radius
        }
        return ratio
    }

    /// F 2222 > r_ref / c₀ = 1852: bańka r 24 i r 74 staje w ε = c₀ · F / r_ref = 1,2 (± 2 %), środkiem za krawędzią ściany, bez
    /// odrzuconego kroku i bez przyczyny strażnika w żadnym kroku. Bańka r 74 (c 0,04) osiada wolno, w czasie rzędu 10 s, więc przebieg trwa 60 s symulacji.
    func testBubblePressedHarderThanTheEdgeLimitSettlesBehindTheEdgeAtComplianceTimesForce() async throws {
        let force: Float = 2222
        let expected = baseCompliance * force / referenceRadius
        for (radius, seconds) in [(Float(24), 6.0), (74, 60)] {
            let ratio = try await settle(radius: radius, force: force, seconds: seconds)
            XCTAssertEqual(ratio, expected, accuracy: 0.02 * expected, "r \(radius): końcowe ε")
            XCTAssertGreaterThan(ratio, 1, "r \(radius): środek przed krawędzią ściany")
        }
    }

    /// Cienka ściana (x od 0 do 8) i F 4000, przy którym ε = 2,16 sięgnęłoby za tylną krawędź (ε > 1 + T / r = 1,33): środek
    /// zostaje po wewnętrznej stronie tylnej krawędzi (8 − margines), żaden krok nie jest odrzucony ani nie kończy się za ścianą.
    func testCenterPressedThroughAThinWallStopsInsideTheBackEdge() async throws {
        let radius: Float = 24, thickness: Float = 8, force: Float = 4000
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: material())
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        setup = setup.add(.rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: 9_100),
            vertices: [[0, -100], [thickness, -100], [thickness, 100], [0, 100]], motionRole: .static,
            physicsMaterialID: CrowdScene.wallMaterial, renderMaterialID: CrowdScene.style)))
        _ = world.submit(try setup.add(CrowdScene.bubble(1, at: WorldPoint(-radius - 20, 0), radius: radius,
                                                         drivePolicy: policy(force: force)))
            .beginPlayerDrive(CrowdScene.id(1), target: WorldPoint(2000, 0)))
        var deepest: Float = -.infinity
        var final = WorldPoint.zero
        for step in 0..<240 {
            let frame = try await advance(world, step: step, label: "cienka ściana")
            if world.diagnostics.lastAdvanceIssue != nil { break }
            let position = try XCTUnwrap(frame.objects[CrowdScene.id(1)], "krok \(step): bańka zniknęła").position
            XCTAssertLessThan(position.x, thickness, "krok \(step): środek za tylną krawędzią: \(position)")
            deepest = max(deepest, position.x)
            final = position
        }
        XCTAssertEqual(final.x, thickness - 2 * CrowdScene.guardMargin, accuracy: 1e-3, "środek po wewnętrznej stronie tylnej krawędzi")
        XCTAssertEqual(final.y, 0, accuracy: 1e-2, "środek zsunięty wzdłuż ściany")
        XCTAssertGreaterThan(deepest, thickness - 0.01, "środek nie doszedł do tylnej krawędzi")
    }
}
