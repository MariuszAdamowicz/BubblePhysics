import BubblePhysics
import BubblePhysicsMetalRender
import BubblePhysicsMetalRenderBenchmark
import Metal
import XCTest

/// Równoważność optymalizacji etapu 8 (P-B-80, G10-AC5): scena akceptacyjna po 120 krokach daje bity stanu
/// obiektów i konturów równe wzorcowi zapisanemu przed pierwszą optymalizacją ścieżki CPU. Optymalizacja, która
/// zmienia choć jeden bit opublikowanego stanu, jest zmianą zachowania i ma tu zawieść.
///
/// Wzorzec pochodzi z Apple M1 Pro (jedyne urządzenie wzorca); na innym test wzorca jest pomijany z powodem,
/// bo GPU innej rodziny może legalnie zaokrąglać inaczej.
@MainActor
final class AcceptanceEquivalenceTests: XCTestCase {
    private typealias Scene = PublicWorldStressBenchmark.Scene

    /// Urządzenie, na którym zapisano wzorzec.
    private static let referenceDeviceName = "Apple M1 Pro"
    private static let referenceSteps = 120
    /// Commit, na którym policzono wzorzec (kod biblioteki bez zmian od c614fe0 do 177147b), bez żadnej
    /// optymalizacji ścieżki CPU etapu 8.
    private static let referenceCommit = "c614fe0"
    /// Wzorzec zapisany przed zadaniem 84 (bez żadnej optymalizacji ścieżki CPU etapu 8).
    /// Bez limitu λ pary (`pairCorrectionLimit = false`, CD-D-20): wzorzec bez zmian, ten sam co w v2.1.0.
    /// Hashe zaktualizowane w wycinku 3 wydania 3.0.0 (jednostronne krawędzie statycznych wielokątów, CD-D-3, CD-D-4): ściany tej sceny mają
    /// grubość 1, więc dawna druga sprężyna od tylnej krawędzi i podwójny kontakt wierzchołka znikają i pozycje baniek przy ścianach
    /// się zmieniają (Apple M1 Pro, ta sama scena i kroki). Po 10 krokach stan jest jeszcze bit w bit ten sam co przed zmianą.
    private static let referenceObjectHash: UInt64 = 0xfa5767995423d94b
    private static let referenceContourHash: UInt64 = 0xd9560fd38a0a2ecc
    /// Z limitem λ pary (CD-D-9, domyślnie): limit zmienia przesunięcia w gęstej scenie, więc stan i kontury po 120
    /// krokach mają nowe hashe (Apple M1 Pro, ta sama scena i kroki co wzorzec).
    private static let pairLimitObjectHash: UInt64 = 0xa0e2db9372a992c1
    private static let pairLimitContourHash: UInt64 = 0xcb1ed172437bc536

    private struct Published {
        let frame: WorldFrame
        let objectHash: UInt64
        let contourHash: UInt64
        let contourCount: Int
    }

    /// Te same kroki co benchmark: transakcja kroku (indeks od 0), `advance` o 1/60 s, bez renderu.
    /// `viaCommandBuffer` idzie ścieżką benchmarku, `advance(by:commandBuffer:encodeRender:)` z pustym `encodeRender`.
    private func run(steps: Int, device: MTLDevice, viaCommandBuffer: Bool = false,
                     pairCorrectionLimit: Bool = true) async throws -> Published {
        let scene = Scene.acceptance
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try scene.configuration(), device: device,
            solverIterationLimit: 4, pairCorrectionLimit: pairCorrectionLimit)
        world.submit(try scene.initialTransaction(assets: try XCTUnwrap(world.assets)))
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var frame = WorldFrame(transactionReceipts: [], events: [])
        for index in 0..<steps {
            if let transaction = try scene.stepTransaction(step: index) { world.submit(transaction) }
            if viaCommandBuffer {
                let command = try XCTUnwrap(queue.makeCommandBuffer())
                frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {}
                XCTAssertEqual(command.status, .completed, "krok \(index + 1)")
            } else {
                frame = await world.advance(by: 1.0 / 60)
            }
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index + 1)")
        }
        let contours = world.debugContourSnapshot()
        return Published(frame: frame, objectHash: PublishedStateHash.objects(frame),
            contourHash: PublishedStateHash.contours(contours), contourCount: contours.count)
    }

    private func assertMatchesReference(viaCommandBuffer: Bool, pairCorrectionLimit: Bool = true) async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.name == Self.referenceDeviceName,
            "wzorzec pochodzi z \(Self.referenceDeviceName), a to jest \(device.name)")
        let published = try await run(steps: Self.referenceSteps, device: device, viaCommandBuffer: viaCommandBuffer,
                                      pairCorrectionLimit: pairCorrectionLimit)
        let objectHash = pairCorrectionLimit ? Self.pairLimitObjectHash : Self.referenceObjectHash
        let contourHash = pairCorrectionLimit ? Self.pairLimitContourHash : Self.referenceContourHash
        let origin = "wzorzec: \(Self.referenceDeviceName), \(Self.referenceSteps) kroków, commit \(Self.referenceCommit)"
        XCTAssertEqual(published.frame.stepIndex, UInt64(Self.referenceSteps))
        // 300 baniek, 4 ściany i trójkąt kinematyczny.
        XCTAssertEqual(published.frame.objects.count, 305)
        XCTAssertEqual(published.contourCount, 300)
        XCTAssertEqual(String(published.objectHash, radix: 16), String(objectHash, radix: 16),
            "stan obiektów (frame.objects) sceny akceptacyjnej różni się od wzorca sprzed optymalizacji (\(origin))")
        XCTAssertEqual(String(published.contourHash, radix: 16), String(contourHash, radix: 16),
            "kontury baniek sceny akceptacyjnej różnią się od wzorca sprzed optymalizacji (\(origin))")
    }

    func testAcceptanceSceneStateAfter120StepsEqualsTheReferencePattern() async throws {
        try await assertMatchesReference(viaCommandBuffer: false)
    }

    /// Ścieżka z buforem aplikacji (ta, którą idzie benchmark i przyszłe optymalizacje) daje te same bity co `advance(by:)`.
    func testAcceptanceSceneThroughTheCommandBufferPathEqualsTheSameReferencePattern() async throws {
        try await assertMatchesReference(viaCommandBuffer: true)
    }

    /// Bliźniak (CD-D-20): z wyłączonym limitem λ pary scena daje bity wzorca z v2.1.0.
    func testAcceptanceSceneStateAfter120StepsEqualsTheReferencePatternWithoutPairCorrectionLimit() async throws {
        try await assertMatchesReference(viaCommandBuffer: false, pairCorrectionLimit: false)
    }

    func testAcceptanceSceneThroughTheCommandBufferPathEqualsTheSameReferencePatternWithoutPairCorrectionLimit() async throws {
        try await assertMatchesReference(viaCommandBuffer: true, pairCorrectionLimit: false)
    }

    /// Sam wzorzec nic nie znaczy, gdy hash jest stały albo przebieg nie jest powtarzalny: scena się rusza,
    /// hash to widzi, a dwa przebiegi na tym samym urządzeniu są identyczne (podstawa porównania z wzorcem).
    /// Test działa na każdym GPU, więc jest sprawdzeniem domyślnej ścieżki z limitem λ pary także poza urządzeniem wzorca
    /// (F-11): oba przebiegi z limitem mają każdy krok przyjęty (asercja w `run`), a stan różni się od bliźniaka bez limitu,
    /// czyli limit naprawdę działa w tej scenie.
    func testHashSeesTheSceneMoveAndTwoRunsAreIdentical() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let early = try await run(steps: 1, device: device)
        let first = try await run(steps: Self.referenceSteps, device: device, pairCorrectionLimit: true)
        let second = try await run(steps: Self.referenceSteps, device: device, pairCorrectionLimit: true)
        let twin = try await run(steps: Self.referenceSteps, device: device, pairCorrectionLimit: false)
        XCTAssertNotEqual(early.objectHash, first.objectHash)
        XCTAssertNotEqual(early.contourHash, first.contourHash)
        XCTAssertEqual(first.objectHash, second.objectHash, "stan obiektów różni się między przebiegami")
        XCTAssertEqual(first.contourHash, second.contourHash, "kontury różnią się między przebiegami")
        XCTAssertEqual(first.frame.objects.count, 305)
        XCTAssertNotEqual(first.objectHash, twin.objectHash, "limit λ pary nie zmienia stanu sceny akceptacyjnej")
    }
}
