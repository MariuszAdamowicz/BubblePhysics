import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// P-B-20 (G12-AC2): na scenie stress-300 limit k kandydatów na obiekt nie jest przekroczony
/// i ma co najmniej dwukrotny zapas nad zmierzonym maksimum (z `WorldDiagnostics`).
@MainActor
final class ContactCandidateMarginTests: XCTestCase {
    func testStress300KeepsCandidateLimitWithAtLeastTwofoldMargin() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try Stress300Scene.configuration(),
            device: device, solverIterationLimit: 4)
        world.submit(try Stress300Scene.initialTransaction())
        var maximum = 0
        for index in 0..<300 {
            if index > 0 { world.submit(try Stress300Scene.triangleReplacement(step: index)) }
            _ = await world.advance(by: 1.0 / 60)
            maximum = max(maximum, world.diagnostics.maximumContactCandidatesPerObject)
            XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 0, "krok \(index + 1): limit k przekroczony")
        }
        XCTAssertGreaterThan(maximum, 0, "stress-300 ma kontakty, więc diagnostyka musi raportować kandydatów")
        XCTAssertLessThanOrEqual(maximum * 2, BubbleWorld.contactCandidateLimit,
            "zmierzone maksimum \(maximum) bez dwukrotnego zapasu względem k = \(BubbleWorld.contactCandidateLimit)")
    }

    /// P-B-63: scena mieszana (200 baniek, 60 brył, 10 więzów, 5 kinematycznych) ma wiersze kandydatów brył,
    /// których stress-300 nie ma; zapas k musi wystarczyć także tutaj.
    func testMixedSceneKeepsCandidateLimitWithAtLeastTwofoldMargin() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try MixedScene.configuration(),
            device: device, solverIterationLimit: 4)
        world.submit(try MixedScene.initialTransaction())
        var maximum = 0
        var frame = WorldFrame(transactionReceipts: [], events: [])
        for index in 0..<300 {
            if let transaction = try MixedScene.stepTransaction(step: index) { world.submit(transaction) }
            frame = await world.advance(by: 1.0 / 60)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index + 1): klatka się nie udała")
            maximum = max(maximum, world.diagnostics.maximumContactCandidatesPerObject)
            XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 0, "krok \(index + 1): limit k przekroczony")
        }
        XCTAssertEqual(frame.objects.count, 264, "200 baniek, 60 brył i 4 ściany")
        XCTAssertGreaterThan(maximum, 0, "scena mieszana ma kontakty, więc diagnostyka musi raportować kandydatów")
        XCTAssertLessThanOrEqual(maximum * 2, BubbleWorld.contactCandidateLimit,
            "zmierzone maksimum \(maximum) bez dwukrotnego zapasu względem k = \(BubbleWorld.contactCandidateLimit)")
    }

    /// G12-AC2 w scenie akceptacyjnej: ten sam przebieg co benchmark (30 klatek rozgrzewki i 300 mierzonych), więc obejmuje
    /// chwilę, gdy bańki są już upakowane, a kinematyczny trójkąt wjeżdża w nie.
    func testAcceptanceSceneKeepsCandidateLimitWithAtLeastTwofoldMarginOverTheBenchmarkRun() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = PublicWorldStressBenchmark.Scene.acceptance
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try scene.configuration(),
            device: device, solverIterationLimit: 4)
        world.submit(try scene.initialTransaction(assets: try XCTUnwrap(world.assets)))
        var maximum = 0
        for index in 0..<(30 + 300) {
            if let transaction = try scene.stepTransaction(step: index) { world.submit(transaction) }
            _ = await world.advance(by: 1.0 / 60)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index + 1): klatka się nie udała")
            maximum = max(maximum, world.diagnostics.maximumContactCandidatesPerObject)
            XCTAssertEqual(world.diagnostics.contactCandidateOverflow, 0, "krok \(index + 1): limit k przekroczony")
        }
        XCTAssertGreaterThan(maximum, 0, "scena akceptacyjna ma kontakty, więc diagnostyka musi raportować kandydatów")
        XCTAssertLessThanOrEqual(maximum * 2, BubbleWorld.contactCandidateLimit,
            "zmierzone maksimum \(maximum) bez dwukrotnego zapasu względem k = \(BubbleWorld.contactCandidateLimit)")
    }
}
