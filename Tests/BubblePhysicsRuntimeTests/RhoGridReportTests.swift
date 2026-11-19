import BubblePhysics
import Foundation
import XCTest

/// P-B-14 (G2-AC3): raport siatki twardnienia kontaktu miękkiego, dla autora, bez progu.
///
/// Opt-in: bez `BUBBLE_PHYSICS_RHO_GRID_REPORT=1` test jest pomijany i nie zapisuje nic. Z flagą liczy siatkę
/// c₀ ∈ {1e-3, 2,5e-3, 4e-3} × kc ∈ {0, 1,5, 3} (r_ref = 20, s = 1) i zapisuje `docs/benchmarks/v2.3.0-rho-grid-<data>.md`.
///
/// Scena każdego punktu: bańka o m = 1,36 (masa bańki „2” ze strojenia T3) i r = 20 startuje `gap` od ściany lewej i jest
/// dociągana do niej gumką w nasyceniu, czyli stałą siłą `maximumForce` (cel leży głęboko w ścianie, więc K · naciągnięcie
/// przekracza limit przez cały przebieg). Ściśnięcie ε = δ / r, δ = r − odległość środka od płaszczyzny ściany. Raport podaje:
/// maksimum przejściowe ε (uderzenie), równowagę statyczną (średnia z ostatniej pół sekundy), wartość ze wzoru
/// ε = a (1 − ε)^kc, a = c₀ (r / r_ref)^s F / r (ρ z pozycji rzeczywistej), oraz wartość z poprawką
/// ρ = 1 − ε − F · dt² / (m · r) (solver liczy ρ z pozycji przewidzianej, głębszej w spoczynku o F · dt² / m).
@MainActor
final class RhoGridReportTests: XCTestCase {
    private let dt = CrowdScene.step
    private let radius: Float = 20
    private let referenceRadius: Float = 20
    private let mass: Float = 1.36
    private let stiffness: Float = 20
    private let force: Float = 1500
    private let gap: Float = 30
    private let seconds = 8.0

    private let baseCompliances: [Float] = [1e-3, 2.5e-3, 4e-3]
    private let compressionExponents: [Float] = [0, 1.5, 3]

    private struct Point {
        var base: Float
        var exponent: Float
        var peak: Float
        var equilibrium: Float
        var formula: Float
        var correctedFormula: Float
        var speedAtEnd: Float
    }

    /// Rozwiązuje ε = a · max(0, ρ₀ − ε)^k bisekcją na [0, 1]; lewa strona rośnie, prawa maleje, więc pierwiastek jest jeden.
    private func solve(a: Float, exponent: Float, offset: Float) -> Float {
        func residual(_ e: Float) -> Float { e - a * pow(max(0, 1 - offset - e), exponent) }
        var low: Float = 0, high: Float = 1
        for _ in 0..<80 {
            let mid = (low + high) / 2
            if residual(mid) > 0 { high = mid } else { low = mid }
        }
        return (low + high) / 2
    }

    private func measure(base: Float, exponent: Float) async throws -> Point {
        let material = try CrowdScene.softBubblePhysics(base: base, compressionExponent: exponent)
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: material)
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        let policy = try BubbleDrivePolicy(rigidifies: false, bandStiffness: stiffness, bandDamping: 5, maximumForce: force)
        let touching = CrowdScene.interiorHalfSize.x - radius
        let target = WorldPoint(-(touching + 90), 0)
        _ = world.submit(setup
            .add(try CrowdScene.bubble(1, at: WorldPoint(-(touching - gap), 0), radius: radius, mass: mass, drivePolicy: policy))
            .beginPlayerDrive(CrowdScene.id(1), target: target))
        let steps = Int((seconds / dt).rounded()), tail = Int((0.5 / dt).rounded())
        var peak: Float = 0, tailDepths: [Float] = [], lastSpeed: Float = 0
        for index in 0..<steps {
            let frame = await world.advance(by: dt)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "c₀ = \(base), kc = \(exponent), krok \(index)")
            let state = try XCTUnwrap(frame.objects[CrowdScene.id(1)])
            let depth = CrowdScene.wallDepth(of: state, targetRadius: radius) / radius
            peak = max(peak, depth)
            if index >= steps - tail { tailDepths.append(depth) }
            lastSpeed = (state.velocity.x * state.velocity.x + state.velocity.y * state.velocity.y).squareRoot()
        }
        let a = base * pow(radius / referenceRadius, 1) * force / radius
        let correction = force * Float(dt * dt) / (mass * radius)
        return Point(base: base, exponent: exponent, peak: peak,
                     equilibrium: tailDepths.reduce(0, +) / Float(tailDepths.count),
                     formula: solve(a: a, exponent: exponent, offset: 0),
                     correctedFormula: solve(a: a, exponent: exponent, offset: correction), speedAtEnd: lastSpeed)
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private func format(_ value: Float) -> String { String(format: "%.4f", value) }

    func testWritesTheHardeningGridReport() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["BUBBLE_PHYSICS_RHO_GRID_REPORT"] == "1",
                          "raport siatki jest opt-in: BUBBLE_PHYSICS_RHO_GRID_REPORT=1")
        var points: [Point] = []
        for base in baseCompliances {
            for exponent in compressionExponents { points.append(try await measure(base: base, exponent: exponent)) }
        }
        XCTAssertEqual(points.count, baseCompliances.count * compressionExponents.count)
        for point in points {
            XCTAssertTrue(point.peak.isFinite && point.equilibrium.isFinite, "c₀ = \(point.base), kc = \(point.exponent)")
            XCTAssertGreaterThan(point.peak, 0, "bańka musiała dotknąć ściany")
            XCTAssertGreaterThanOrEqual(point.peak, point.equilibrium - 1e-4, "maksimum przejściowe nie jest poniżej równowagi")
            XCTAssertLessThan(point.speedAtEnd, 1, "bańka stoi pod koniec przebiegu")
        }

        let date = ISO8601DateFormatter().string(from: Date()).prefix(10)
        var lines = [
            "# Siatka twardnienia kontaktu miękkiego (v2.3.0, G2-AC3)",
            "",
            "Raport z testu opt-in `RhoGridReportTests` (`BUBBLE_PHYSICS_RHO_GRID_REPORT=1 swift test --filter BubblePhysicsRuntimeTests.RhoGridReportTests`). Bez progu, ocenia autor.",
            "",
            "Scena: bańka m = \(mass), r = \(Int(radius)), r_ref = \(Int(referenceRadius)), s = 1, krok 1/\(Int((1 / dt).rounded())), start \(Int(gap)) od ściany lewej, "
                + "dociągana do niej gumką w nasyceniu (K = \(Int(stiffness)), D = 5, `maximumForce` F = \(Int(force)), cel 90 w głąb ściany), `damping` = 0, "
                + "\(Int(seconds)) s. Ściśnięcie ε = δ / r.",
            "",
            "- maksimum: największe ε w przebiegu (uderzenie w ścianę),",
            "- równowaga: średnie ε z ostatniej pół sekundy,",
            "- wzór: ε = a (1 − ε)^kc, a = c₀ (r / r_ref)^s F / r,",
            "- wzór z poprawką: ε = a (1 − ε − F · dt² / (m · r))^kc (solver liczy ρ z pozycji przewidzianej).",
            "",
            "| c₀ | kc | maksimum ε | równowaga ε | wzór ε | wzór z poprawką ε | prędkość na końcu |",
            "|---|---|---|---|---|---|---|"]
        for point in points {
            lines.append("| \(point.base) | \(point.exponent) | \(format(point.peak)) | \(format(point.equilibrium)) | "
                + "\(format(point.formula)) | \(format(point.correctedFormula)) | \(format(point.speedAtEnd)) |")
        }
        let url = repositoryRoot.appendingPathComponent("docs/benchmarks/v2.3.0-rho-grid-\(date).md")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}
