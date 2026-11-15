import BubblePhysics
@testable import BubblePhysicsRuntime
import simd
import XCTest

/// Podatność kontaktu z materiału (P-B-18 – P-B-26): odrzucenie złej wartości i przepełnienia Float w transakcji oraz ugięcie
/// bańki dociśniętej do ściany. Wszystko przez publiczny `BubbleWorld` na urządzeniu Metal.
///
/// Sceny docisku są z `CrowdSceneSupport.swift`: bańka stoi przy wewnętrznej krawędzi ściany, a `MotorDrive` pcha ją w ścianę stałą
/// siłą F. W stanie ustalonym wgniecenie jest proporcjonalne do c · F, gdzie c = c₀ · (r / r_ref)^s · ρ^k, ze współczynnikiem
/// solvera ≈ 3,85 (8 iteracji Jacobiego nie domyka α ≫ invMass): przy r_ref = 20, c₀ = 1e-3 i F = 300 bańka r = 20 (s = 1)
/// ugina się o 1,156. Siła musi zostać w zakresie liniowym: powyżej F ≈ 600 (m = 1) prędkość w stronę ściany przekracza
/// `restSpeed` tłumika kontaktu (max(40, 2r)), tłumik się wyłącza i bańka dochodzi do δ = r (probe przy F = 1000, c₀ = 4e-3).
@MainActor
final class ContactComplianceTests: XCTestCase {
    private let soft = PhysicsMaterialID(rawValue: 1)
    private let hard = PhysicsMaterialID(rawValue: 3)
    private let style = RenderMaterialID(rawValue: 1)
    private let step = 1.0 / 60
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    /// Docisk i skala wgnieceń: δ ≈ 3,85 · c₀ · F · (r / 20)^s · ρ^k, w zakresie liniowym także dla 2F.
    private let force: Float = 300
    private let base: Float = 1e-3
    /// 2 s symulacji (pomiar po 2 s), okno uspokojenia od 1 s do 2 s.
    private let steps = 120
    private let settleWindow = 60..<120

    // MARK: scena docisku

    private func pressWorld(material: PhysicsMaterial, _ build: (WorldTransaction) throws -> WorldTransaction) async throws -> BubbleWorld {
        try await CrowdScene.makeWorld(bubble: material, extra: build)
    }
    /// δ w kroku `steps`, czyli po 2 s.
    private func finalDepth(_ series: [UInt64: [Float]], _ value: UInt64, file: StaticString = #filePath, line: UInt = #line) throws -> Float {
        try XCTUnwrap(series[value]?.last, "brak pomiaru bańki \(value)", file: file, line: line)
    }
    /// P-B-24: δ w oknie od 1 s do 2 s waha się o mniej niż 0,02 · r.
    private func assertSettled(_ series: [UInt64: [Float]], _ value: UInt64, radius: Float, _ name: String,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let all = try XCTUnwrap(series[value], file: file, line: line)
        let window = Array(all[settleWindow])
        let spread = (window.max() ?? 0) - (window.min() ?? 0)
        XCTAssertLessThan(spread, 0.02 * radius, "\(name): δ waha się o \(spread) w oknie 1–2 s (δ = \(window.last ?? 0))", file: file, line: line)
    }

    // MARK: transakcje (P-B-18 – P-B-20)

    private func transactionWorld(material: PhysicsMaterial, hardMaterial: PhysicsMaterial,
                                  _ setup: (WorldTransaction) throws -> WorldTransaction = { $0 }) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-300, -300], max: [300, 300]), fixedTimeStep: step))
        _ = world.submit(try setup(WorldTransaction()
            .updatePhysicsMaterial(soft, material: material)
            .updatePhysicsMaterial(hard, material: hardMaterial)
            .updateRenderMaterial(style, material: try RenderMaterial())))
        let frame = await world.advance(by: step)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertEqual(frame.transactionReceipts.count, 1, "przygotowanie sceny musi zostać przyjęte")
        return world
    }
    private func bubble(_ value: UInt64, at position: WorldPoint, radius: Float, material: PhysicsMaterialID? = nil,
                        override: Float? = nil) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, targetRadius: radius, mass: radius * radius / 400,
                                     physicsMaterialID: material ?? soft, renderMaterialID: style, eventInterest: [.didAdd],
                                     contactCompliance: override))
    }
    private func result(_ value: UInt64, material: PhysicsMaterialID? = nil, override: Float? = nil) -> BubbleResult {
        BubbleResult(id: id(value), physicsMaterialID: material ?? soft, renderMaterialID: style, eventInterest: [.didAdd],
                     contactCompliance: override)
    }
    private func run(_ world: BubbleWorld, _ transaction: WorldTransaction)
        async -> (frame: WorldFrame, token: TransactionToken, rejection: TransactionRejection?) {
        let token = world.submit(transaction)
        let frame = await world.advance(by: step)
        var found: TransactionRejection?
        for case .transactionRejected(let rejected, let rejection) in frame.events where rejected == token { found = rejection }
        return (frame, token, found)
    }
    private func assertRejected(_ outcome: (frame: WorldFrame, token: TransactionToken, rejection: TransactionRejection?),
                                at index: Int, _ reason: TransactionRejectionReason, _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.rejection, TransactionRejection(operationIndex: index, reason: reason), name, file: file, line: line)
        XCTAssertFalse(outcome.frame.transactionReceipts.contains { $0.token == outcome.token }, name, file: file, line: line)
    }
    private func assertAccepted(_ outcome: (frame: WorldFrame, token: TransactionToken, rejection: TransactionRejection?),
                                _ name: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(outcome.rejection, name, file: file, line: line)
        XCTAssertTrue(outcome.frame.transactionReceipts.contains { $0.token == outcome.token }, name, file: file, line: line)
    }
    /// Świat idzie dalej: następna transakcja z poprawnym punktem i podatnością jest przyjęta.
    private func assertNextStepAccepted(_ world: BubbleWorld, file: StaticString = #filePath, line: UInt = #line) async throws {
        let outcome = await run(world, WorldTransaction().add(try bubble(900, at: [250, 250], radius: 2, material: hard)))
        assertAccepted(outcome, "następny krok", file: file, line: line)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, file: file, line: line)
    }

    private let invalidOverrides: [Float] = [-1e-3, .nan, .infinity]
    private func defaultMaterials() throws -> (PhysicsMaterial, PhysicsMaterial) {
        (try CrowdScene.softBubblePhysics(base: 1e-3), try PhysicsMaterial(kind: .bubble))
    }

    // P-B-18 (G4-AC7): zła wartość nadpisania w `BubbleResult` odrzuca transakcję, źródła zostają.
    func testResultValidationRejectsInvalidContactComplianceOverrideInMergeAndSplit() async throws {
        let (softMaterial, hardMaterial) = try defaultMaterials()
        let world = try await transactionWorld(material: softMaterial, hardMaterial: hardMaterial) {
            $0.add(try bubble(1, at: [-10, 0], radius: 5)).add(try bubble(2, at: [10, 0], radius: 5))
                .add(try bubble(3, at: [100, 100], radius: 10))
        }
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        for override in invalidOverrides {
            let merge = await run(world, WorldTransaction().mergeBubbles([id(1), id(2)], result: result(100, override: override)))
            assertRejected(merge, at: 0, reason, "scalenie, nadpisanie \(override)")
            XCTAssertNotNil(merge.frame.objects[id(1)], "źródło scalenia zostaje")
            XCTAssertNotNil(merge.frame.objects[id(2)], "źródło scalenia zostaje")
            XCTAssertNil(merge.frame.objects[id(100)])

            for (first, second) in [(override, Float?.none), (Float?.none, override)] {
                let split = await run(world, WorldTransaction().splitBubble(id(3),
                    first: BubbleSplitPart(result: result(101, override: first), share: 0.5),
                    second: BubbleSplitPart(result: result(102, override: second), share: 0.5)))
                assertRejected(split, at: 0, reason, "podział, nadpisania \(String(describing: first)) i \(String(describing: second))")
                XCTAssertNotNil(split.frame.objects[id(3)], "źródło podziału zostaje")
            }
        }
        try await assertNextStepAccepted(world)
        // Poprawne nadpisanie, w tym 0, jest przyjęte.
        let split = await run(world, WorldTransaction().splitBubble(id(3),
            first: BubbleSplitPart(result: result(103, override: 0), share: 0.5),
            second: BubbleSplitPart(result: result(104, override: 2e-3), share: 0.5)))
        assertAccepted(split, "podział z poprawnymi nadpisaniami")
    }

    /// Nadpisanie z `BubbleResult` trafia do deskryptora wyniku scalenia i obu części podziału (stager, CPU); bez nadpisania zostaje `nil`.
    func testResultOverrideLandsInTheDescriptorOfMergeAndSplitResults() throws {
        func override(of state: RuntimeState, _ value: UInt64) throws -> Float? {
            guard case .bubble(let descriptor) = try XCTUnwrap(state.objects[id(value)]).descriptor else { XCTFail("nie bańka"); return nil }
            return descriptor.contactCompliance
        }
        let (softMaterial, hardMaterial) = try defaultMaterials()
        var state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-300, -300], max: [300, 300]), fixedTimeStep: step))
        state = try TransactionStager.stage(WorldTransaction().updatePhysicsMaterial(soft, material: softMaterial)
            .updatePhysicsMaterial(hard, material: hardMaterial).updateRenderMaterial(style, material: try RenderMaterial())
            .add(bubble(1, at: [-10, 0], radius: 5)).add(bubble(2, at: [10, 0], radius: 5)).add(bubble(3, at: [100, 100], radius: 10)),
            against: state).state
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)], result: result(100, override: 3e-3)),
                                                 against: state).state
        XCTAssertEqual(try override(of: merged, 100), 3e-3)
        let split = try TransactionStager.stage(WorldTransaction().splitBubble(id(3),
            first: BubbleSplitPart(result: result(101, override: 0), share: 0.5),
            second: BubbleSplitPart(result: result(102), share: 0.5)), against: state).state
        XCTAssertEqual(try override(of: split, 101), 0)
        XCTAssertNil(try override(of: split, 102))
        let plain = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)], result: result(100)), against: state).state
        XCTAssertNil(try override(of: plain, 100))
    }

    // MARK: najgorsza α (P-B-19, P-B-20)

    /// Materiał, którego podatność przepełnia Float dopiero od r/r_ref > ok. 2: c₀ = 1, r_ref = 1, s = 70 (4^70 ≈ 1,4e42 > FLT_MAX).
    private func overflowing() throws -> PhysicsMaterial {
        try CrowdScene.softBubblePhysics(base: 1, radiusExponent: 70, referenceRadius: 1)
    }
    /// Ten sam wykładnik przy c₀ = 0: potęgi nie są liczone, więc nic nie przepełnia.
    private func overflowingExponentWithoutCompliance() throws -> PhysicsMaterial {
        try CrowdScene.softBubblePhysics(base: 0, radiusExponent: 70, referenceRadius: 1)
    }

    // P-B-19 (G3-AC8): `add`, `replace`, scalenie i podział z podatnością przepełniającą Float.
    func testWorstAlphaRejectsAddReplaceMergeAndSplitWhenAlphaOverflows() async throws {
        let world = try await transactionWorld(material: overflowing(), hardMaterial: overflowingExponentWithoutCompliance()) {
            // Źródła i bańka do podmiany stoją na materiale z c₀ = 0 albo na małym promieniu (1^70 = 1).
            $0.add(try bubble(1, at: [-10, 0], radius: 3.5, material: hard)).add(try bubble(2, at: [10, 0], radius: 3.5, material: hard))
                .add(try bubble(3, at: [100, 100], radius: 6, material: hard))
                .add(try bubble(4, at: [-100, 100], radius: 1))
        }
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        assertRejected(await run(world, WorldTransaction().add(try bubble(10, at: [200, 0], radius: 4))), at: 0, reason, "add")
        assertRejected(await run(world, WorldTransaction().replace(id(4), with: try bubble(4, at: [-100, 100], radius: 4))), at: 0, reason, "replace")
        assertRejected(await run(world, WorldTransaction().mergeBubbles([id(1), id(2)], result: result(100))), at: 0, reason, "scalenie")
        assertRejected(await run(world, WorldTransaction().splitBubble(id(3),
            first: BubbleSplitPart(result: result(101), share: 0.5), second: BubbleSplitPart(result: result(102), share: 0.5))),
            at: 0, reason, "podział")
        try await assertNextStepAccepted(world)
        // Granica: r = 2 daje 2^70 ≈ 1,2e21, a α = 4e24 mieści się w Float.
        assertAccepted(await run(world, WorldTransaction().add(try bubble(11, at: [200, 0], radius: 2))), "add r = 2")
        // c₀ = 0 przy tym samym wykładniku przechodzi we wszystkich czterech operacjach.
        assertAccepted(await run(world, WorldTransaction().add(try bubble(12, at: [200, 100], radius: 4, material: hard))), "add, c₀ = 0")
        assertAccepted(await run(world, WorldTransaction().replace(id(4), with: try bubble(4, at: [-100, 100], radius: 4, material: hard))),
                       "replace, c₀ = 0")
        assertAccepted(await run(world, WorldTransaction().mergeBubbles([id(1), id(2)], result: result(100, material: hard))),
                       "scalenie, c₀ = 0")
        assertAccepted(await run(world, WorldTransaction().splitBubble(id(3),
            first: BubbleSplitPart(result: result(101, material: hard), share: 0.5),
            second: BubbleSplitPart(result: result(102, material: hard), share: 0.5))), "podział, c₀ = 0")
    }

    // Nadpisanie c₀ na bańce wchodzi do najgorszej α: c₀ = 0 na materiale przepełniającym przechodzi, a duże nadpisanie nie.
    func testWorstAlphaUsesTheBubbleOverrideOfBaseCompliance() async throws {
        let world = try await transactionWorld(material: overflowing(), hardMaterial: overflowingExponentWithoutCompliance())
        assertAccepted(await run(world, WorldTransaction().add(try bubble(1, at: [200, 0], radius: 4, override: 0))), "add z nadpisaniem 0")
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        assertRejected(await run(world, WorldTransaction().add(try bubble(2, at: [200, 100], radius: 4, override: 1))), at: 0, reason,
                       "add z nadpisaniem 1")
        // Wynik scalenia z nadpisaniem 0 przechodzi mimo materiału przepełniającego.
        let merge = await run(world, WorldTransaction().add(try bubble(3, at: [-10, 0], radius: 3.5, override: 0))
            .add(try bubble(4, at: [10, 0], radius: 3.5, override: 0))
            .mergeBubbles([id(3), id(4)], result: result(100, override: 0)))
        assertAccepted(merge, "scalenie z nadpisaniem 0")
    }

    /// Dokładny wzór najgorszej α: α_cfg + 2 · c_worst / dt², z dt = 1/60 (dt² ≈ 2,8e-4): 2c/dt² = 7200 · c. FLT_MAX ≈ 3,4e38.
    func testWorstAlphaCountsTheFactorTwoTheTimeStepAndTheMinimumRhoForNegativeCompressionExponent() async throws {
        func accepts(base: Float, compressionExponent: Float = 0) async throws -> Bool {
            let material = try CrowdScene.softBubblePhysics(base: base, radiusExponent: 0, compressionExponent: compressionExponent,
                                                            referenceRadius: 1)
            let world = try await transactionWorld(material: material, hardMaterial: PhysicsMaterial(kind: .bubble))
            return await run(world, WorldTransaction().add(try bubble(1, at: [0, 0], radius: 2))).rejection == nil
        }
        // c = 7e34 jest skończone, c/dt² = 2,5e38 też, ale 2c/dt² = 5e38 przepełnia Float.
        let overflowsOnlyWithFactorTwo = try await accepts(base: 7e34)
        XCTAssertFalse(overflowsOnlyWithFactorTwo, "2c/dt² przepełnia Float")
        let fitsWithFactorTwo = try await accepts(base: 4e34)
        XCTAssertTrue(fitsWithFactorTwo, "2c/dt² = 2,9e38 mieści się w Float")
        // k = −1: c_worst = c₀ · ρ_min^k = 100 · c₀ (ρ_min = 0,01).
        let negativeExponentOverflows = try await accepts(base: 3e34, compressionExponent: -1)
        XCTAssertFalse(negativeExponentOverflows, "ρ_min^k = 100 przepełnia α")
        let positiveExponentFits = try await accepts(base: 3e34, compressionExponent: 1)
        XCTAssertTrue(positiveExponentFits, "k > 0 nie powiększa c_worst")
    }

    // Ujemny wykładnik promienia: przy s < 0 najgorszy jest mniejszy koniec przedziału promieni.
    func testWorstAlphaTakesTheSmallerRadiusWhenTheRadiusExponentIsNegative() async throws {
        let material = try CrowdScene.softBubblePhysics(base: 1, radiusExponent: -70, referenceRadius: 1)
        let world = try await transactionWorld(material: material, hardMaterial: PhysicsMaterial(kind: .bubble)) {
            $0.add(try bubble(1, at: [0, 0], radius: 4))
        }
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        assertRejected(await run(world, WorldTransaction().add(try bubble(2, at: [100, 100], radius: 0.25))), at: 0, reason, "add r = 0,25")
        assertRejected(await run(world, WorldTransaction().startTransition(
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(0.25), duration: 0.5))), at: 0, reason, "startTransition do r = 0,25")
        assertAccepted(await run(world, WorldTransaction().startTransition(
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(2), duration: 0.5))), "startTransition do r = 2")
    }

    // Przejście promienia, które już trwa, wchodzi do przedziału: stan końcowy przepełnia α także wtedy, gdy bieżący promień jest mały.
    func testWorstAlphaIncludesTheScheduledEndOfARunningRadiusTransition() async throws {
        let world = try await transactionWorld(material: overflowing(), hardMaterial: overflowingExponentWithoutCompliance()) {
            $0.add(try bubble(1, at: [0, 0], radius: 1))
        }
        // Wolne przejście do r = 2 (2^70 ≈ 1,2e21 mieści się w Float przy r_ref = 1): trwa przez cały test.
        assertAccepted(await run(world, WorldTransaction().startTransition(
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(2), duration: 5))), "startTransition do r = 2")
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        // r_ref = 0,5: bieżący promień 1 daje 2^70 ≈ 1,2e21 (skończone), ale cel przejścia r = 2 daje 4^70 ≈ 1,4e42, więc samo
        // przedział z celem przejścia odrzuca aktualizację materiału.
        assertRejected(await run(world, WorldTransaction().updatePhysicsMaterial(soft,
            material: try CrowdScene.softBubblePhysics(base: 1, radiusExponent: 70, referenceRadius: 0.5))), at: 0, reason,
            "updatePhysicsMaterial z celem przejścia r = 2")
        // Bez przejścia ten sam materiał dla bańki r = 1 jest przyjęty: r_ref = 0,5 jest skończone.
        let calm = try await transactionWorld(material: overflowing(), hardMaterial: overflowingExponentWithoutCompliance()) {
            $0.add(try bubble(1, at: [0, 0], radius: 1))
        }
        assertAccepted(await run(calm, WorldTransaction().updatePhysicsMaterial(soft,
            material: try CrowdScene.softBubblePhysics(base: 1, radiusExponent: 70, referenceRadius: 0.5))), "updatePhysicsMaterial bez przejścia")
    }

    // P-B-20 (G3-AC9): `startTransition` promienia po przepełnieniu odrzucone; promień bez zmian.
    func testWorstAlphaRejectsRadiusTransitionThatOverflowsAndKeepsTheRadius() async throws {
        let world = try await transactionWorld(material: overflowing(), hardMaterial: overflowingExponentWithoutCompliance()) {
            $0.add(try bubble(1, at: [0, 0], radius: 1))
        }
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        let rejected = await run(world, WorldTransaction().startTransition(
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(4), duration: 0.5)))
        assertRejected(rejected, at: 0, reason, "startTransition do r = 4")
        var frame = rejected.frame
        for _ in 0..<60 { frame = await world.advance(by: step) }
        XCTAssertEqual(CrowdScene.effectiveRadius(of: try XCTUnwrap(frame.objects[id(1)])), 1, accuracy: 0.05,
                       "promień nie rośnie po odrzuconym przejściu")
        // Mniejszy cel mieści się w Float i jest przyjęty.
        assertAccepted(await run(world, WorldTransaction().startTransition(
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(2), duration: 0.5))), "startTransition do r = 2")
    }

    // P-B-20 (G3-AC9): `updatePhysicsMaterial`, po którym α przepełnia Float, odrzucone; materiał bez zmian.
    func testWorstAlphaRejectsMaterialUpdateThatOverflowsAndKeepsTheMaterial() async throws {
        let moderate = try CrowdScene.softBubblePhysics(base: 1e-3, radiusExponent: 2, referenceRadius: 20)
        let world = try await transactionWorld(material: moderate, hardMaterial: overflowingExponentWithoutCompliance()) {
            $0.add(try bubble(1, at: [0, 0], radius: 4))
        }
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        // Z r_ref = 1 bańka r = 4 ma 4^70 ≈ 1,4e42: stan po aktualizacji przepełnia Float.
        assertRejected(await run(world, WorldTransaction().updatePhysicsMaterial(soft, material: try overflowing())), at: 0, reason,
                       "updatePhysicsMaterial")
        // Materiał nie zmienił się: nowa bańka r = 4 na nim przechodzi, a gdyby zmieniono, byłaby odrzucona.
        assertAccepted(await run(world, WorldTransaction().add(try bubble(2, at: [100, 100], radius: 4))),
                       "add na niezmienionym materiale")
        // Materiał, po którym α jest skończone, jest przyjęty.
        assertAccepted(await run(world, WorldTransaction().updatePhysicsMaterial(soft,
            material: try CrowdScene.softBubblePhysics(base: 1e-3, radiusExponent: 3, referenceRadius: 20))), "updatePhysicsMaterial skończone")
    }

    // MARK: prawo promienia i wykładnik ściśnięcia (P-B-21 – P-B-24)

    private func twoRadii(material: PhysicsMaterial, steps: Int = 120) async throws -> [UInt64: [Float]] {
        let world = try await pressWorld(material: material) {
            var t = try CrowdScene.pressedBubble($0, 1, y: -200, radius: 20, force: self.force)
            t = try CrowdScene.pressedBubble(t, 2, y: 200, radius: 40, force: self.force)
            return t
        }
        return await CrowdScene.wallPress(world: world, [(1, 20, .left), (2, 40, .left)], steps: steps)
    }

    // P-B-21 (G4-AC1) i P-B-24: s = 2, większe względne wgniecenie ma bańka r = 40, a δ jest uspokojone.
    func testRadiusLawWithExponent2DentsTheLargerBubbleMoreInRelativeTerms() async throws {
        let series = try await twoRadii(material: CrowdScene.softBubblePhysics(base: base, radiusExponent: 2))
        let small = try finalDepth(series, 1) / 20, large = try finalDepth(series, 2) / 40
        XCTAssertGreaterThan(small, 0.01, "bańka r = 20 uginała się: δ/r = \(small)")
        XCTAssertGreaterThan(large, small, "s = 2: δ/r dla r = 40 (\(large)) ma być większe niż dla r = 20 (\(small))")
        try assertSettled(series, 1, radius: 20, "r = 20, s = 2")
        try assertSettled(series, 2, radius: 40, "r = 40, s = 2")
    }

    // P-B-22 (G4-AC2) i P-B-24: s = 0 odwraca kolejność, a s = 1 daje równe względne wgniecenie.
    func testRadiusLawWithExponent0DentsTheSmallerBubbleMoreInRelativeTerms() async throws {
        let series = try await twoRadii(material: CrowdScene.softBubblePhysics(base: base, radiusExponent: 0))
        let small = try finalDepth(series, 1) / 20, large = try finalDepth(series, 2) / 40
        XCTAssertGreaterThan(large, 0.01, "bańka r = 40 uginała się: δ/r = \(large)")
        XCTAssertGreaterThan(small, large, "s = 0: δ/r dla r = 20 (\(small)) ma być większe niż dla r = 40 (\(large))")
        try assertSettled(series, 1, radius: 20, "r = 20, s = 0")
        try assertSettled(series, 2, radius: 40, "r = 40, s = 0")
    }

    func testRadiusLawWithExponent1GivesEqualRelativeDent() async throws {
        let series = try await twoRadii(material: CrowdScene.softBubblePhysics(base: base, radiusExponent: 1))
        let small = try finalDepth(series, 1) / 20, large = try finalDepth(series, 2) / 40
        XCTAssertGreaterThan(small, 0.01, "bańka r = 20 uginała się: δ/r = \(small)")
        XCTAssertEqual(large, small, accuracy: 0.2 * small, "s = 1: równe δ/r, jest \(small) i \(large)")
    }

    private func doubledForce(material: PhysicsMaterial) async throws -> (single: Float, doubled: Float, series: [UInt64: [Float]]) {
        let world = try await pressWorld(material: material) {
            var t = try CrowdScene.pressedBubble($0, 1, y: -200, radius: 20, force: self.force)
            t = try CrowdScene.pressedBubble(t, 2, y: 200, radius: 20, force: 2 * self.force)
            return t
        }
        let series = await CrowdScene.wallPress(world: world, [(1, 20, .left), (2, 20, .left)], steps: steps)
        return (try finalDepth(series, 1) / 20, try finalDepth(series, 2) / 20, series)
    }

    // P-B-23 (G4-AC3), k = 0: podwojona siła daje 2× ± 20%.
    func testRadiusLawWithoutCompressionExponentDoublesTheDentWithDoubleForce() async throws {
        let result = try await doubledForce(material: CrowdScene.softBubblePhysics(base: base, compressionExponent: 0))
        XCTAssertGreaterThan(result.single, 0.01, "bańka uginała się: δ/r = \(result.single)")
        XCTAssertEqual(result.doubled / result.single, 2, accuracy: 0.4, "k = 0: δ/r \(result.single) → \(result.doubled)")
        try assertSettled(result.series, 1, radius: 20, "F, k = 0")
        try assertSettled(result.series, 2, radius: 20, "2F, k = 0")
    }

    // P-B-23 (G4-AC3), k > 0, i P-B-24: podwojona siła zwiększa δ/r mniej niż dwukrotnie, a bańka jest uspokojona (ρ^k nie drga).
    func testCompressionExponentMakesDoubledForceDentLessThanTwice() async throws {
        let result = try await doubledForce(material: CrowdScene.softBubblePhysics(base: base, compressionExponent: 2))
        XCTAssertGreaterThan(result.single, 0.01, "bańka uginała się: δ/r = \(result.single)")
        XCTAssertGreaterThan(result.doubled, result.single, "większa siła ugina bardziej")
        XCTAssertLessThan(result.doubled / result.single, 2, "k = 2: δ/r \(result.single) → \(result.doubled) rośnie mniej niż 2×")
    }

    // P-B-24 dla k > 0: ρ^k reaguje z opóźnieniem jednego kroku, a wygładzenie ρ ma to uspokoić.
    func testSettlesWithCompressionExponentInWindowBetweenOneAndTwoSeconds() async throws {
        for exponent in [Float(1), 2] {
            let result = try await doubledForce(material: CrowdScene.softBubblePhysics(base: base, compressionExponent: exponent))
            XCTAssertGreaterThan(result.single, 0.01, "k = \(exponent): bańka uginała się")
            try assertSettled(result.series, 1, radius: 20, "F, k = \(exponent)")
            try assertSettled(result.series, 2, radius: 20, "2F, k = \(exponent)")
        }
    }

    // MARK: twarda przy miękkiej (P-B-25) i nadpisania (P-B-26)

    // P-B-25 (G4-AC4): bańka c₀ = 0 dociska miękką przy ścianie; twarda zachowuje promień, ściska miękka.
    func testHardAgainstSoftKeepsTheHardRadiusAndCompressesTheSoftOne() async throws {
        // Miękka bańka leży przy lewej ścianie, twarda stoi za nią (styk) i pcha ją w ścianę.
        let world = try await CrowdScene.makeWorld(bubble: CrowdScene.softBubblePhysics(base: base)) { setup in
            setup.updatePhysicsMaterial(CrowdScene.secondBubbleMaterial, material: try CrowdScene.softBubblePhysics(base: 0))
                .add(try CrowdScene.bubble(1, at: [-160, 0], radius: 20))
                .add(try CrowdScene.bubble(2, at: [-120, 0], radius: 20, material: CrowdScene.secondBubbleMaterial))
                .setMotorDrive(self.id(2), drive: try MotorDrive(force: [-self.force, 0]))
        }
        var frame = await world.advance(by: step)
        for _ in 0..<steps { frame = await world.advance(by: step) }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        let softState = try XCTUnwrap(frame.objects[id(1)]), hardState = try XCTUnwrap(frame.objects[id(2)])
        let hardRadius = CrowdScene.effectiveRadius(of: hardState)
        XCTAssertEqual(hardRadius, 20, accuracy: 0.2, "twarda bańka zachowuje promień docelowy (± 1%), jest \(hardRadius)")
        XCTAssertGreaterThan(CrowdScene.wallDepth(of: softState, targetRadius: 20), 0.5, "miękka ma δ > 0 względem ściany")
        let distance = simd.distance(softState.position, hardState.position)
        XCTAssertLessThan(distance, 40 - 0.5, "odległość środków mniejsza od sumy promieni docelowych, jest \(distance)")
    }

    private func finalDepths(_ values: [UInt64: [Float]], _ ids: [UInt64]) throws -> [Float] {
        try ids.map { try finalDepth(values, $0) }
    }

    // P-B-26 (G4-AC5): nadpisanie c₀ w `BubbleDescriptor` ugina tylko tę bańkę.
    func testOverrideOfBaseComplianceInDescriptorBendsOnlyThatBubble() async throws {
        let material = try CrowdScene.softBubblePhysics(base: base)
        let world = try await pressWorld(material: material) {
            var t = try CrowdScene.pressedBubble($0, 1, y: -200, radius: 20, force: self.force)
            t = try CrowdScene.pressedBubble(t, 2, y: 0, radius: 20, force: self.force, contactCompliance: 0)
            t = try CrowdScene.pressedBubble(t, 3, y: 200, radius: 20, force: self.force, contactCompliance: 2 * self.base)
            return t
        }
        let series = await CrowdScene.wallPress(world: world, [(1, 20, .left), (2, 20, .left), (3, 20, .left)], steps: steps)
        let depths = try finalDepths(series, [1, 2, 3])
        XCTAssertGreaterThan(depths[0], 0.5, "bez nadpisania ugina się jak materiał: δ = \(depths[0])")
        XCTAssertLessThan(depths[1], 0.25 * depths[0], "nadpisanie 0 daje bańkę twardą: δ = \(depths[1]) wobec \(depths[0])")
        XCTAssertGreaterThan(depths[2], 1.5 * depths[0], "nadpisanie 2·c₀ ugina bardziej: δ = \(depths[2]) wobec \(depths[0])")
        // Bańka bez nadpisania zachowuje się tak samo jak sama w świecie bez pozostałych.
        let alone = try await pressWorld(material: material) { try CrowdScene.pressedBubble($0, 1, y: -200, radius: 20, force: self.force) }
        let aloneSeries = await CrowdScene.wallPress(world: alone, [(1, 20, .left)], steps: steps)
        XCTAssertEqual(depths[0], try finalDepth(aloneSeries, 1), accuracy: 0.05 * 20, "bez nadpisania: jak bez innych baniek")
    }

    // P-B-26 (G4-AC5): nadpisanie w `BubbleResult` scalenia ugina tylko wynik, który je ma.
    func testOverrideOfBaseComplianceInMergeResultBendsOnlyThatResult() async throws {
        let world = try await pressWorld(material: CrowdScene.softBubblePhysics(base: base)) { setup in
            setup.add(try CrowdScene.bubble(1, at: [-100, -159], radius: 10)).add(try CrowdScene.bubble(2, at: [-100, -141], radius: 10))
                .add(try CrowdScene.bubble(3, at: [-100, 141], radius: 10)).add(try CrowdScene.bubble(4, at: [-100, 159], radius: 10))
        }
        let plain = BubbleResult(id: id(100), physicsMaterialID: CrowdScene.bubbleMaterial, renderMaterialID: CrowdScene.style,
                                 eventInterest: [.didAdd])
        let overridden = BubbleResult(id: id(101), physicsMaterialID: CrowdScene.bubbleMaterial, renderMaterialID: CrowdScene.style,
                                      eventInterest: [.didAdd], contactCompliance: 0)
        _ = world.submit(WorldTransaction().mergeBubbles([id(1), id(2)], result: plain).mergeBubbles([id(3), id(4)], result: overridden))
        let frame = await world.advance(by: step)
        XCTAssertNotNil(frame.objects[id(100)]); XCTAssertNotNil(frame.objects[id(101)])
        _ = world.submit(WorldTransaction().setMotorDrive(id(100), drive: try MotorDrive(force: [-force, 0]))
            .setMotorDrive(id(101), drive: try MotorDrive(force: [-force, 0])))
        let radius = Float(200).squareRoot() // r = √(10² + 10²)
        let series = await CrowdScene.wallPress(world: world, [(100, radius, .left), (101, radius, .left)], steps: 240)
        let plainDepth = try finalDepth(series, 100), hardDepth = try finalDepth(series, 101)
        XCTAssertGreaterThan(plainDepth, 0.3, "wynik bez nadpisania ugina się jak materiał: δ = \(plainDepth)")
        XCTAssertLessThan(hardDepth, 0.3 * plainDepth, "wynik z nadpisaniem 0 jest twardy: δ = \(hardDepth) wobec \(plainDepth)")
    }

    // P-B-26 (G4-AC5): nadpisania w obu częściach podziału działają osobno.
    func testOverrideOfBaseComplianceInSplitPartsBendsOnlyThatPart() async throws {
        let world = try await pressWorld(material: CrowdScene.softBubblePhysics(base: base)) {
            $0.add(try CrowdScene.bubble(1, at: [0, 0], radius: 20))
        }
        let hardPart = BubbleResult(id: id(101), physicsMaterialID: CrowdScene.bubbleMaterial, renderMaterialID: CrowdScene.style,
                                    eventInterest: [.didAdd], contactCompliance: 0)
        let softPart = BubbleResult(id: id(102), physicsMaterialID: CrowdScene.bubbleMaterial, renderMaterialID: CrowdScene.style,
                                    eventInterest: [.didAdd])
        _ = world.submit(WorldTransaction().splitBubble(id(1), first: BubbleSplitPart(result: hardPart, share: 0.5),
                                                        second: BubbleSplitPart(result: softPart, share: 0.5)))
        let frame = await world.advance(by: step)
        XCTAssertNotNil(frame.objects[id(101)]); XCTAssertNotNil(frame.objects[id(102)])
        // Części rozchodzą się do przeciwnych ścian: twarda do lewej, miękka do prawej.
        _ = world.submit(WorldTransaction().setMotorDrive(id(101), drive: try MotorDrive(force: [-force, 0]))
            .setMotorDrive(id(102), drive: try MotorDrive(force: [force, 0])))
        let radius = Float(20) * Float(0.5).squareRoot()
        let series = await CrowdScene.wallPress(world: world, [(101, radius, .left), (102, radius, .right)], steps: 300)
        let hardDepth = try finalDepth(series, 101), softDepth = try finalDepth(series, 102)
        XCTAssertGreaterThan(softDepth, 0.3, "część bez nadpisania ugina się jak materiał: δ = \(softDepth)")
        XCTAssertLessThan(hardDepth, 0.3 * softDepth, "część z nadpisaniem 0 jest twarda: δ = \(hardDepth) wobec \(softDepth)")
    }
}
