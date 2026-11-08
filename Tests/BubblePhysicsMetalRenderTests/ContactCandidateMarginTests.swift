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
}
