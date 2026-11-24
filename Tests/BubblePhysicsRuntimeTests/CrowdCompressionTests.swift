import BubblePhysics
import simd
import XCTest

/// Tłok i narożnik w prawie kontaktu K_c (P-B-27 – P-B-29, po audycie testów spec. 4): krok nie jest odrzucany, środki zostają
/// w ramie ścian, a bańki nie znikają. Testy kontaktu twardego (c₀ = 0) zostały usunięte razem z kontaktem twardym: K_c > 0 jest
/// skończone, a „bardzo twarda” bańka to duże K_c. Scena z `CrowdSceneSupport.swift`; wszystko idzie przez publiczny `BubbleWorld`
/// na urządzeniu Metal.
@MainActor
final class CrowdCompressionTests: XCTestCase {
    /// Wspólne asercje dla przebiegu tłoku. Licznika par zawartych nie ma: zawarcie jest niemożliwe, a para kolidująca ma d > 0.
    /// `centerDepthBehindFrame` (w promieniach docelowych) to dopuszczalna głębokość środka za wewnętrzną krawędzią ściany; 0 wymaga
    /// środków w ramie (w prawie z granicą na promieniu środek nigdy nie dochodzi do krawędzi).
    private func assertCrowdKeptStepsAccepted(_ report: CrowdScene.CrowdReport, world: BubbleWorld, balance: Double,
                                              centerDepthBehindFrame: Float = 0,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(report.firstIssue?.issue,
                     "krok \(report.firstIssue?.step ?? 0) odrzucony: \(String(describing: report.firstIssue?.rejection)), bańk: \(report.addedCount)",
                     file: file, line: line)
        XCTAssertNil(report.failureReason, file: file, line: line)
        XCTAssertNil(world.diagnostics.failureReason, file: file, line: line)
        XCTAssertEqual(report.exitEvents, 0, "didExitSimulationRegion", file: file, line: line)
        XCTAssertEqual(report.vanishedBubbles, 0, "bańki, które zniknęły z klatki", file: file, line: line)
        if centerDepthBehindFrame == 0 {
            XCTAssertTrue(report.outsideFrame.isEmpty, "środek poza ramą: \(report.outsideFrame.prefix(3))", file: file, line: line)
        } else {
            XCTAssertLessThan(report.deepestCenterBehindFrame, centerDepthBehindFrame,
                              "środek za krawędzią ściany (w r): \(report.outsideFrame.prefix(3))", file: file, line: line)
        }
        XCTAssertGreaterThanOrEqual(report.balance, balance, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.steps, 600, "przebieg obejmuje 600 kroków po ostatniej bańce", file: file, line: line)
    }

    /// Narożnik z G1-AC4: bańka r = 20 pchana siłą 3000 po przekątnej w narożnik ramy, za nią tłok 10 baniek. Zwraca bańkę 1 z
    /// ostatniej klatki; asercje kroków i środków w ramie są w środku.
    private func runCorner(material: PhysicsMaterial) async throws -> ObjectState {
        let force = simd_normalize(WorldPoint(1, 1)) * 3_000
        let world = try await CrowdScene.makeWorld(bubble: material) { setup in
            var setup = setup.add(try CrowdScene.bubble(1, at: [140, 280], radius: 20))
                .setMotorDrive(CrowdScene.id(1), drive: try MotorDrive(force: force))
            // Tłok za bańką: 10 baniek r = 20 na siatce, każda napiera na narożnik.
            for index in 0..<10 {
                let identifier = UInt64(2 + index)
                let position = WorldPoint(20 + Float(index % 4) * 45, 150 + Float(index / 4) * 45)
                setup = setup.add(try CrowdScene.bubble(identifier, at: position, radius: 20))
                    .setMotorDrive(CrowdScene.id(identifier), drive: try MotorDrive(force: force))
            }
            return setup
        }
        var lastFrame: WorldFrame?
        for index in 0..<300 {
            let frame = await world.advance(by: CrowdScene.step)
            lastFrame = frame
            let diagnostics = world.diagnostics
            XCTAssertNil(diagnostics.lastAdvanceIssue,
                         "krok \(index) odrzucony: \(String(describing: diagnostics.lastRejectionReason))")
            if diagnostics.lastAdvanceIssue != nil { break }
            for identifier in 1...11 {
                let state = try XCTUnwrap(frame.objects[CrowdScene.id(UInt64(identifier))],
                                          "bańka \(identifier) zniknęła w kroku \(index)")
                XCTAssertTrue(CrowdScene.isInsideFrame(state.position), "krok \(index), bańka \(identifier): \(state.position)")
            }
        }
        return try XCTUnwrap(lastFrame?.objects[CrowdScene.id(1)])
    }

    // MARK: materiał miękki (wycinek 3)

    /// Wgniecenie bańki względem bliższej z dwóch ścian narożnika: δ = r − d, większe z dwóch (x i y).
    private func cornerDepth(_ state: ObjectState) -> Float {
        let corner = CrowdScene.interiorHalfSize
        return 20 - min(corner.x - state.position.x, corner.y - state.position.y)
    }

    // P-B-27: tłok B = 2,5 z materiałem miękkim, a materiał naprawdę działa. W prawie kontaktu środek nigdy nie dochodzi do krawędzi ściany,
    // więc środki zostają w ramie, a średni promień efektywny / docelowy w ostatniej sekundzie jest poniżej 1. Dowodem, że K_c ma wpływ na
    // kontur, jest porównanie dwóch materiałów w tym samym przebiegu (to samo ziarno) przy B = 1,5: bańka 15 razy miększa (K_c = 1333) ma
    // mocniej wgnieciony kontur niż sztywna (K_c = 20 000). Przy B = 2,5 tłok jest tak gęsty, że o konturze decyduje upakowanie, nie materiał
    // (K_c 1333, 5195 i 20 000 dają 0,418; 0,414 i 0,439, bez monotonii), a bańka 100 razy sztywniejsza (K_c ≈ 5 · 10⁵) kończy świat limitem
    // podkroków, bo wzrost promienia wciska bańki w siebie szybciej, niż podkroki nadążają.
    func testSoftCrowdBalance2_5KeepsStepsAcceptedAndSofterMaterialCompressesContoursMore() async throws {
        let softWorld = try await CrowdScene.makeWorld(bubble: CrowdScene.softCrowdPhysics())
        let soft = try await CrowdScene.runCrowd(world: softWorld, balance: 2.5, seed: 2_500, extraSteps: 600)
        assertCrowdKeptStepsAccepted(soft, world: softWorld, balance: 2.5)
        XCTAssertEqual(soft.lastSecond.count, CrowdScene.lastSecondSteps)
        XCTAssertLessThan(soft.meanEffectiveRadiusRatioInLastSecond, 1, "średni promień efektywny / docelowy w ostatniej sekundzie")
        var ratios: [Float: Float] = [:]
        for base: Float in [0.015, 0.001] {   // K_c = r_ref / c₀ = 1333 i 20 000
            let world = try await CrowdScene.makeWorld(bubble: CrowdScene.softBubblePhysics(base: base))
            let report = try await CrowdScene.runCrowd(world: world, balance: 1.5, seed: 2_500, extraSteps: 600)
            assertCrowdKeptStepsAccepted(report, world: world, balance: 1.5)
            XCTAssertEqual(report.lastSecond.count, CrowdScene.lastSecondSteps)
            ratios[base] = report.meanEffectiveRadiusRatioInLastSecond
        }
        let softer = try XCTUnwrap(ratios[0.015]), stiffer = try XCTUnwrap(ratios[0.001])
        XCTAssertLessThan(softer, stiffer, "miększa bańka ma mocniej wgnieciony kontur: K_c 1333 → \(softer), K_c 20 000 → \(stiffer)")
    }

    // P-B-28: silniejszy nacisk (B = 2,5 wobec 1,5, to samo ziarno) mocniej ściska kontury.
    func testSoftCrowdCompressesMoreAtHigherBalance() async throws {
        var ratios: [Double: Float] = [:]
        for balance in [1.5, 2.5] {
            let world = try await CrowdScene.makeWorld(bubble: CrowdScene.softCrowdPhysics())
            let report = try await CrowdScene.runCrowd(world: world, balance: balance, seed: 2_500, extraSteps: 600)
            XCTAssertNil(report.firstIssue?.issue, "B = \(balance): krok \(report.firstIssue?.step ?? 0) odrzucony")
            XCTAssertEqual(report.lastSecond.count, CrowdScene.lastSecondSteps)
            ratios[balance] = report.meanEffectiveRadiusRatioInLastSecond
        }
        let low = try XCTUnwrap(ratios[1.5]), high = try XCTUnwrap(ratios[2.5])
        XCTAssertGreaterThan(low, 0, "stosunek promienia efektywnego do docelowego jest zmierzony")
        XCTAssertLessThan(high, low, "średni promień efektywny / docelowy: B = 2,5 → \(high), B = 1,5 → \(low)")
    }

    /// Sama pchana bańka w narożniku, bez tłoku: wgniecenie względem ścian da się odczytać, bo przy tłoku bańka dociera do ściany
    /// (δ ≈ r) także przy sztywnym materiale.
    private func singleCornerDepth(material: PhysicsMaterial) async throws -> Float {
        let force = simd_normalize(WorldPoint(1, 1)) * 3_000
        let world = try await CrowdScene.makeWorld(bubble: material) {
            $0.add(try CrowdScene.bubble(1, at: [160, 300], radius: 20))
                .setMotorDrive(CrowdScene.id(1), drive: try MotorDrive(force: force))
        }
        var frame = await world.advance(by: CrowdScene.step)
        for _ in 0..<180 { frame = await world.advance(by: CrowdScene.step) }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        return cornerDepth(try XCTUnwrap(frame.objects[CrowdScene.id(1)]))
    }

    // P-B-29: narożnik z materiałem miękkim nie odrzuca kroku i trzyma środek w ramie; wgniecenie pchanej bańki jest większe niż przy
    // bańce 10 razy sztywniejszej; opór γ = 5 tłumi odbicia, bo bez oporu bańka pchana stałą siłą odbija się od narożnika bez końca.
    // Pełna scena z tłokiem nie rozróżnia materiałów po δ, więc δ porównuje scena z samą pchaną bańką.
    func testSoftCornerPushedByTenBubblesKeepsStepsAcceptedAndDentsMoreThanAStiffBubble() async throws {
        let material = try CrowdScene.softBubblePhysics(base: 3e-4, damping: 5)
        let pressed = try await runCorner(material: material)
        let distance = simd_length(pressed.position - CrowdScene.interiorHalfSize)
        XCTAssertLessThan(distance, 20 * Float(2).squareRoot() + 1, "bańka 1 nie dotarła do narożnika: \(pressed.position)")
        let soft = try await singleCornerDepth(material: material)
        let stiff = try await singleCornerDepth(material: CrowdScene.softBubblePhysics(base: 3e-5, damping: 5))
        XCTAssertGreaterThan(soft, stiff + 0.05, "wgniecenie δ pchanej bańki: miękka \(soft), sztywna \(stiff)")
    }
}
