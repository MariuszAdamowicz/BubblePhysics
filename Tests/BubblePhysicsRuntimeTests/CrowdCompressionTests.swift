import BubblePhysics
import simd
import XCTest

/// Tłok i narożnik przy kontakcie twardym (P-B-13, P-B-14) i miękkim (P-B-27 – P-B-29): krok nie jest odrzucany, środki zostają
/// w ramie ścian, a bańki nie znikają. Scena z `CrowdSceneSupport.swift`; wszystko idzie przez publiczny `BubbleWorld` na urządzeniu Metal.
@MainActor
final class CrowdCompressionTests: XCTestCase {
    /// Wspólne asercje G1-AC1, G1-AC2 i G2-AC5 dla przebiegu tłoku.
    private func assertCrowdKeptStepsAccepted(_ report: CrowdScene.CrowdReport, world: BubbleWorld, balance: Double,
                                              file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(report.firstIssue?.issue,
                     "krok \(report.firstIssue?.step ?? 0) odrzucony: \(String(describing: report.firstIssue?.rejection)), bańk: \(report.addedCount)",
                     file: file, line: line)
        XCTAssertNil(report.failureReason, file: file, line: line)
        XCTAssertNil(world.diagnostics.failureReason, file: file, line: line)
        XCTAssertEqual(report.exitEvents, 0, "didExitSimulationRegion", file: file, line: line)
        XCTAssertEqual(report.vanishedBubbles, 0, "bańki, które zniknęły z klatki", file: file, line: line)
        XCTAssertTrue(report.outsideFrame.isEmpty, "środek poza ramą: \(report.outsideFrame.prefix(3))", file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.balance, balance, file: file, line: line)
        XCTAssertTrue(report.wasContainedCountFinite, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.minimumContainedPairs, 0, file: file, line: line)
        XCTAssertGreaterThanOrEqual(report.steps, 600, "przebieg obejmuje 600 kroków po ostatniej bańce", file: file, line: line)
    }

    // P-B-13
    func testHardCrowdBalance2_5KeepsStepsAcceptedAndCentersInTheFrame() async throws {
        let world = try await CrowdScene.makeWorld()
        let report = try await CrowdScene.runCrowd(world: world, balance: 2.5, seed: 2_500, extraSteps: 600)
        assertCrowdKeptStepsAccepted(report, world: world, balance: 2.5)
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

    // P-B-14
    func testHardCornerPushedByTenBubblesKeepsStepsAcceptedAndCenterInTheFrame() async throws {
        let pressed = try await runCorner(material: CrowdScene.bubblePhysics())
        // Napęd naprawdę dociska bańkę 1 do narożnika: jej środek leży blisko punktu (180, 320), a nie w miejscu startu (140, 280).
        // Bańka r = 20 oparta o obie ściany ma środek w odległości r·√2 od narożnika, start jest o 40·√2 od niego.
        let corner = CrowdScene.interiorHalfSize
        let distance = simd_length(pressed.position - corner)
        XCTAssertLessThan(distance, 20 * Float(2).squareRoot() + 1, "bańka 1 nie dotarła do narożnika: \(pressed.position)")
    }

    // MARK: materiał miękki (wycinek 3)

    /// Wgniecenie bańki względem bliższej z dwóch ścian narożnika: δ = r − d, większe z dwóch (x i y).
    private func cornerDepth(_ state: ObjectState) -> Float {
        let corner = CrowdScene.interiorHalfSize
        return 20 - min(corner.x - state.position.x, corner.y - state.position.y)
    }

    // P-B-27: tłok B = 2,5 z materiałem miękkim jak P-B-13, a materiał naprawdę działa: nakładanie par większe niż przy c₀ = 0.
    func testSoftCrowdBalance2_5KeepsStepsAcceptedAndOverlapsMoreThanHard() async throws {
        let softWorld = try await CrowdScene.makeWorld(bubble: CrowdScene.softCrowdPhysics())
        let soft = try await CrowdScene.runCrowd(world: softWorld, balance: 2.5, seed: 2_500, extraSteps: 600)
        assertCrowdKeptStepsAccepted(soft, world: softWorld, balance: 2.5)
        let hardWorld = try await CrowdScene.makeWorld(bubble: CrowdScene.softBubblePhysics(base: 0))
        let hard = try await CrowdScene.runCrowd(world: hardWorld, balance: 2.5, seed: 2_500, extraSteps: 600)
        XCTAssertNil(hard.firstIssue?.issue, "przebieg odniesienia z c₀ = 0")
        XCTAssertEqual(soft.lastSecond.count, CrowdScene.lastSecondSteps)
        XCTAssertEqual(hard.lastSecond.count, CrowdScene.lastSecondSteps)
        XCTAssertGreaterThan(soft.meanOverlapInLastSecond, hard.meanOverlapInLastSecond,
                             "średnie nakładanie par z ostatniej sekundy: miękki \(soft.meanOverlapInLastSecond), twardy \(hard.meanOverlapInLastSecond)")
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

    /// Sama pchana bańka w narożniku, bez tłoku: wgniecenie względem ścian da się odczytać, bo przy tłoku bańka dociera do marginesu
    /// strażnika (δ ≈ r) także przy kontakcie twardym.
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

    // P-B-29: narożnik z P-B-14 z materiałem miękkim nie odrzuca kroku i trzyma środek w ramie; wgniecenie pchanej bańki jest
    // większe niż przy c₀ = 0. Pełna scena z tłokiem nie rozróżnia materiałów po δ: bańka 1 dochodzi tam do marginesu strażnika
    // (δ = 19,998) także przy c₀ = 0, więc δ porównuje scena z samą pchaną bańką.
    func testSoftCornerPushedByTenBubblesKeepsStepsAcceptedAndDentsMoreThanHard() async throws {
        let material = try CrowdScene.softBubblePhysics(base: 3e-4)
        let pressed = try await runCorner(material: material)
        let distance = simd_length(pressed.position - CrowdScene.interiorHalfSize)
        XCTAssertLessThan(distance, 20 * Float(2).squareRoot() + 1, "bańka 1 nie dotarła do narożnika: \(pressed.position)")
        let soft = try await singleCornerDepth(material: material)
        let hard = try await singleCornerDepth(material: CrowdScene.softBubblePhysics(base: 0))
        XCTAssertGreaterThan(soft, hard + 0.05, "wgniecenie δ pchanej bańki: miękka \(soft), twarda \(hard)")
    }
}
