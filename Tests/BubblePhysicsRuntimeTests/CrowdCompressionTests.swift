import BubblePhysics
import simd
import XCTest

/// Tłok i narożnik przy kontakcie twardym (P-B-13, P-B-14) i miękkim (P-B-27 – P-B-29): krok nie jest odrzucany, środki zostają
/// w ramie ścian, a bańki nie znikają. Scena z `CrowdSceneSupport.swift`; wszystko idzie przez publiczny `BubbleWorld` na urządzeniu Metal.
@MainActor
final class CrowdCompressionTests: XCTestCase {
    /// Wspólne asercje G1-AC1, G1-AC2 i G2-AC5 dla przebiegu tłoku. Licznika par zawartych nie sprawdzają: przy B = 2,5 pola kół
    /// są 2,5 raza większe od wnętrza i część par zostaje zawarta w równowadze (probe: 14 przy c₀ = 0, 7 przy materiale miękkim,
    /// tyle samo po 600, 1800 i 3600 krokach). Spadek licznika do 0 sprawdzają przebiegi bez takiego nadmiaru pól.
    /// `centerDepthBehindFrame` (w promieniach docelowych) to dopuszczalna głębokość środka za wewnętrzną krawędzią ściany; 0 wymaga
    /// środków w ramie. Od 3.0.2 (BF-D-5) środek miękkiej bańki dociśniętej siłą F > r_ref / c₀ stoi za krawędzią w ε = c₀ · F / r_ref,
    /// więc tłok miękki może mieć środki za krawędzią; bańka twarda (c = 0) nie.
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

    // P-B-13
    func testHardCrowdBalance2_5KeepsStepsAcceptedAndCentersInTheFrame() async throws {
        let world = try await CrowdScene.makeWorld()
        let report = try await CrowdScene.runCrowd(world: world, balance: 2.5, seed: 2_500, extraSteps: 600)
        assertCrowdKeptStepsAccepted(report, world: world, balance: 2.5)
    }

    // Solver rozsuwa pary „bańka w bańce” w kilku krokach: przy B = 1 po 600 krokach od ostatniej bańki żadnej pary zawartej już
    // nie ma (przy c₀ = 0 i B = 1,5 jedna para zostaje zawarta w równowadze).
    func testHardCrowdBalance1SeparatesAllContainedPairs() async throws {
        let world = try await CrowdScene.makeWorld()
        let report = try await CrowdScene.runCrowd(world: world, balance: 1, seed: 2_500, extraSteps: 600)
        assertCrowdKeptStepsAccepted(report, world: world, balance: 1)
        XCTAssertGreaterThan(report.peakContainedPairs, 0, "pary zawarte w trakcie przebiegu")
        XCTAssertEqual(report.lastContainedPairs, 0, "pary zawarte po ostatnim kroku")
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

    // P-B-27: tłok B = 2,5 z materiałem miękkim jak P-B-13, a materiał naprawdę działa. Od v2.3.0 (G4, CD-D-16) kontakt miękki jest
    // sprężyną z pełną korektą prędkości, więc rozkład nakładania nie dowodzi już działania materiału: probe (c₀ = 3,85e-3, to samo
    // ziarno) dał 670 par nakładających się na klatkę wobec 729 dla c₀ = 0, średnie nakładanie 23,3 wobec 16,7 i największe 93,3 wobec
    // 81,2, bo sprężyny w gęstym tłoku zostawiają część par zawartych (58 po ostatnim kroku), a dawne oczekiwanie (więcej par płyciej,
    // mniejsze maksimum) wynikało z częściowej korekty prędkości i limitu λ pary. Dowodem działania jest kontur: tylko bańka z c > 0
    // ma wgniecenie, więc średni promień efektywny / docelowy spada poniżej 1 (probe: 0,16 wobec 1,00 przy c₀ = 0).
    func testSoftCrowdBalance2_5KeepsStepsAcceptedAndCompressesContoursUnlikeHard() async throws {
        let softWorld = try await CrowdScene.makeWorld(bubble: CrowdScene.softCrowdPhysics())
        let soft = try await CrowdScene.runCrowd(world: softWorld, balance: 2.5, seed: 2_500, extraSteps: 600)
        // Od 3.0.2 (BF-D-5) środek miękkiej bańki może stać za krawędzią ściany: probe (to samo ziarno) dał trzy bańki r 44–47, najgłębiej
        // 0,18 r za krawędzią (ε ≈ 1,18). Próg 0,5 r odróżnia mocne zgniecenie od przebicia ściany grubości 48.
        assertCrowdKeptStepsAccepted(soft, world: softWorld, balance: 2.5, centerDepthBehindFrame: 0.5)
        let hardWorld = try await CrowdScene.makeWorld(bubble: CrowdScene.softBubblePhysics(base: 0))
        let hard = try await CrowdScene.runCrowd(world: hardWorld, balance: 2.5, seed: 2_500, extraSteps: 600)
        XCTAssertNil(hard.firstIssue?.issue, "przebieg odniesienia z c₀ = 0")
        XCTAssertEqual(soft.lastSecond.count, CrowdScene.lastSecondSteps)
        XCTAssertEqual(hard.lastSecond.count, CrowdScene.lastSecondSteps)
        let hardRatio = hard.meanEffectiveRadiusRatioInLastSecond, softRatio = soft.meanEffectiveRadiusRatioInLastSecond
        XCTAssertEqual(hardRatio, 1, accuracy: 0.01, "c₀ = 0: bez wgniecenia konturu, średni promień efektywny / docelowy \(hardRatio)")
        // Pomiar 0,16; próg 0,5 odrzuca materiał, którego siła spadła kilkukrotnie, a nie tylko c = 0.
        XCTAssertLessThan(softRatio, 0.5,
                          "średni promień efektywny / docelowy w ostatniej sekundzie: miękki \(softRatio), twardy \(hardRatio)")
    }

    // P-B-28: silniejszy nacisk (B = 2,5 wobec 1,5, to samo ziarno) mocniej ściska kontury.
    func testSoftCrowdCompressesMoreAtHigherBalance() async throws {
        var ratios: [Double: Float] = [:]
        for balance in [1.5, 2.5] {
            let world = try await CrowdScene.makeWorld(bubble: CrowdScene.softCrowdPhysics())
            let report = try await CrowdScene.runCrowd(world: world, balance: balance, seed: 2_500, extraSteps: 600)
            XCTAssertNil(report.firstIssue?.issue, "B = \(balance): krok \(report.firstIssue?.step ?? 0) odrzucony")
            XCTAssertEqual(report.lastSecond.count, CrowdScene.lastSecondSteps)
            // Przy B = 1,5 materiał miękki rozsuwa wszystkie pary zawarte (przy B = 2,5 część zostaje w równowadze).
            if balance == 1.5 {
                XCTAssertGreaterThan(report.peakContainedPairs, 0, "B = 1,5: pary zawarte w trakcie przebiegu")
                XCTAssertEqual(report.lastContainedPairs, 0, "B = 1,5: pary zawarte po ostatnim kroku")
            }
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

    // P-B-30 (G4-AC7, CD-D-17, CD-D-18): zawarta para miękka wystrzeliwuje mniejszą bańkę i nie psuje świata. Duża r = 40 w (0, 0),
    // mała r = 12 w całości wewnątrz w (6, 0), przeszkoda r = 20 w (100, 0) na osi wystrzału (+x); masy r² / 400, c₀ = 1e-3 (podatność c₀·r/r_ref),
    // ζ_c = 0, `damping` = 0, `maximumLinearSpeed` = 600. Granicy przesunięcia środka w kroku nie ma: wystrzał jest zamierzony.
    // Od 3.0.1 dashpot kontaktu miękkiego tłumi przy każdej prędkości (BF-D-2), więc przy ζ_c = 1 rozprężenie pary jest krytycznie
    // tłumione i mała bańka nie dolatuje do przeszkody; ζ_c = 0 zostawia nietłumiony wystrzał, który ta scena sprawdza.
    func testSoftContainedPairReleasesWithoutBreakingTheWorld() async throws {
        // Bez `CrowdScene.makeWorld`: krok z wstawieniem baniek jest właśnie tym, w którym zawieranie się rozwiązuje.
        let world = try BubbleWorld(configuration: CrowdScene.configuration())
        var setup = try CrowdScene.resources(bubble: CrowdScene.softBubblePhysics(base: 1e-3, dampingRatio: 0))
        for wall in try CrowdScene.walls() { setup = setup.add(wall) }
        _ = world.submit(setup.add(try CrowdScene.bubble(1, at: [0, 0], radius: 40))
            .add(try CrowdScene.bubble(2, at: [6, 0], radius: 12))
            .add(try CrowdScene.bubble(3, at: [100, 0], radius: 20)))
        let radii: [UInt64: Float] = [1: 40, 2: 12, 3: 20]
        let speedLimit: Float = 600 * (1 + 1e-3)
        var frame = await world.advance(by: CrowdScene.step)
        XCTAssertEqual(frame.transactionReceipts.count, 1, "przygotowanie sceny musi zostać przyjęte")
        var closestToObstacle = Float.greatestFiniteMagnitude
        var firstFreeStep: Int?
        for index in 0..<300 {
            if index > 0 { frame = await world.advance(by: CrowdScene.step) }
            XCTAssertNil(world.diagnostics.lastAdvanceIssue,
                         "krok \(index) odrzucony: \(String(describing: world.diagnostics.lastRejectionReason))")
            if world.diagnostics.lastAdvanceIssue != nil { break }
            for (identifier, radius) in radii {
                let state = try XCTUnwrap(frame.objects[CrowdScene.id(identifier)], "bańka \(identifier) zniknęła w kroku \(index)")
                XCTAssertLessThanOrEqual(simd_length(state.velocity), speedLimit, "krok \(index), bańka \(identifier): prędkość")
                // Nakładanie ze ścianą: r − (odległość środka od wewnętrznej krawędzi), większe z dwóch osi; < r, gdy środek jest w ramie.
                let depth = radius - min(CrowdScene.interiorHalfSize.x - abs(state.position.x),
                                         CrowdScene.interiorHalfSize.y - abs(state.position.y))
                XCTAssertLessThan(depth, radius, "krok \(index), bańka \(identifier): przeszła przez ścianę, \(state.position)")
            }
            let big = try XCTUnwrap(frame.objects[CrowdScene.id(1)]), small = try XCTUnwrap(frame.objects[CrowdScene.id(2)])
            let obstacle = try XCTUnwrap(frame.objects[CrowdScene.id(3)])
            closestToObstacle = min(closestToObstacle, simd_distance(small.position, obstacle.position))
            XCTAssertLessThan(small.position.x, obstacle.position.x, "krok \(index): mała bańka minęła przeszkodę na osi wystrzału")
            let contained = world.diagnostics.containedBubblePairCount
            if contained == 0, firstFreeStep == nil { firstFreeStep = index }
            if firstFreeStep != nil {
                XCTAssertEqual(contained, 0, "krok \(index): para zawarta po tym, jak przestała być zawarta")
                XCTAssertGreaterThanOrEqual(simd_distance(big.position, small.position) + 12, 40 - 1e-3,
                                            "krok \(index): para duża–mała znów zawarta")
            }
        }
        XCTAssertNotNil(firstFreeStep, "para przestaje być zawarta")
        XCTAssertLessThanOrEqual(closestToObstacle, 32.5, "mała bańka dotyka przeszkody (wystrzał dotarł do celu)")
    }
}
