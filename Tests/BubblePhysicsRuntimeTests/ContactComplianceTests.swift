import BubblePhysics
@testable import BubblePhysicsRuntime
import simd
import XCTest

/// Podatność kontaktu z materiału (P-B-18 – P-B-26): odrzucenie złej wartości i przepełnienia Float w transakcji oraz ugięcie
/// bańki dociśniętej do ściany. Wszystko przez publiczny `BubbleWorld` na urządzeniu Metal.
///
/// Sceny docisku są z `CrowdSceneSupport.swift`: bańka stoi przy wewnętrznej krawędzi ściany, a `MotorDrive` pcha ją w ścianę stałą
/// siłą F. Kontakt miękki działa jak sprężyna o podatności c = c₀ · r / r_ref z tłumieniem ζ_c (CD-D-16): do prędkości
/// trafia pełna korekta kontaktów XPBD, więc w stanie ustalonym wgniecenie to dokładnie c · F, bez współczynnika solvera, a bańka
/// stoi (prędkość spoczynkowa 0). Przy r_ref = 20, c₀ = 3,85e-3 i F = 300 bańka r = 20 (s = 1) ugina się o 1,155, czyli tyle samo
/// co przed v2.3.0 przy c₀ = 1e-3 (stary współczynnik 3,85 wynikał z częściowej korekty prędkości, nie z iteracji solvera).
/// Granica liniowości (zmierzona sondą, m = 1, c = 3,85e-3, wgniecenie po 4 s): δ / (c · F) = 1,000 dla F = 300, 1 000, 1 700 i 2 500
/// (δ = 9,6, prawie pół promienia), a dla F = 4 000 bańka dochodzi do δ = r i stosunek rośnie do 1,30. Dawna granica F ≈ 600
/// wynikała z prędkości spoczynkowej w stronę ściany, która wyłączała tłumik kontaktu; teraz bańka stoi. Testy zostają przy
/// F = 300 i 2F = 600, daleko w zakresie liniowym.
@MainActor
final class ContactComplianceTests: XCTestCase {
    private let soft = PhysicsMaterialID(rawValue: 1)
    private let hard = PhysicsMaterialID(rawValue: 3)
    private let style = RenderMaterialID(rawValue: 1)
    private let step = 1.0 / 60
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    /// Docisk i skala wgnieceń: δ = c₀ · F · r / 20, w zakresie liniowym także dla 2F. c₀ = 3,85e-3 daje dla F = 300
    /// to samo wgniecenie ≈ 1,155 co dawne c₀ = 1e-3 ze współczynnikiem 3,85 (G4, CD-D-16).
    private let force: Float = 300
    private let base: Float = 3.85e-3
    /// c₀ pary miękkich baniek w testach podziału wgniecenia i CD-D-12: bez zmian względem v2.2.0.
    private let pairBase: Float = 4e-3
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
    private func bubble(_ value: UInt64, at position: WorldPoint, radius: Float, material: PhysicsMaterialID? = nil) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, targetRadius: radius, mass: radius * radius / 400,
                                     physicsMaterialID: material ?? soft, renderMaterialID: style, eventInterest: [.didAdd]))
    }
    private func result(_ value: UInt64, material: PhysicsMaterialID? = nil) -> BubbleResult {
        BubbleResult(id: id(value), physicsMaterialID: material ?? soft, renderMaterialID: style, eventInterest: [.didAdd])
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
        (try CrowdScene.softBubblePhysics(base: 1e-3), try PhysicsMaterial(kind: .bubble, contactStiffness: 1e9))
    }

    // MARK: najgorsza α (P-B-19, P-B-20)

    /// Materiał, którego α przepełnia Float dopiero od r/r_ref > ok. 2,4: c₀ = 2e34, r_ref = 1, 2 / dt² = 7200, więc r = 2 daje
    /// α = 2,9e38 (FLT_MAX ≈ 3,4e38), a r = 4 daje 5,8e38.
    private func overflowing() throws -> PhysicsMaterial {
        try CrowdScene.softBubblePhysics(base: 2e34, referenceRadius: 1)
    }
    /// Ta sama podatność przy c₀ = 0: kontakt twardy, więc nic nie przepełnia.
    private func hardWithoutCompliance() throws -> PhysicsMaterial {
        try CrowdScene.softBubblePhysics(base: 0, referenceRadius: 1)
    }

    // P-B-19 (G3-AC8): `add`, `replace`, scalenie i podział z podatnością przepełniającą Float.
    func testWorstAlphaRejectsAddReplaceMergeAndSplitWhenAlphaOverflows() async throws {
        let world = try await transactionWorld(material: overflowing(), hardMaterial: hardWithoutCompliance()) {
            // Źródła i bańka do podmiany stoją na materiale z c₀ = 0 albo na małym promieniu (c = 2e34, α = 1,4e38).
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
        // Granica: r = 2 daje c = 4e34, a α = 2,9e38 mieści się w Float.
        assertAccepted(await run(world, WorldTransaction().add(try bubble(11, at: [200, 0], radius: 2))), "add r = 2")
        // c₀ = 0 przechodzi we wszystkich czterech operacjach.
        assertAccepted(await run(world, WorldTransaction().add(try bubble(12, at: [200, 100], radius: 4, material: hard))), "add, c₀ = 0")
        assertAccepted(await run(world, WorldTransaction().replace(id(4), with: try bubble(4, at: [-100, 100], radius: 4, material: hard))),
                       "replace, c₀ = 0")
        assertAccepted(await run(world, WorldTransaction().mergeBubbles([id(1), id(2)], result: result(100, material: hard))),
                       "scalenie, c₀ = 0")
        assertAccepted(await run(world, WorldTransaction().splitBubble(id(3),
            first: BubbleSplitPart(result: result(101, material: hard), share: 0.5),
            second: BubbleSplitPart(result: result(102, material: hard), share: 0.5))), "podział, c₀ = 0")
    }

    /// Dokładny wzór najgorszej α: α_cfg + 2 · c_worst / dt², z dt = 1/60 (dt² ≈ 2,8e-4): 2c/dt² = 7200 · c. FLT_MAX ≈ 3,4e38.
    /// c_worst = c₀ · r_max / r_ref, więc przy r_ref = 1 i r = 2 jest 2 · c₀.
    func testWorstAlphaCountsTheFactorTwoAndTheTimeStep() async throws {
        func accepts(base: Float) async throws -> Bool {
            let material = try CrowdScene.softBubblePhysics(base: base, referenceRadius: 1)
            let world = try await transactionWorld(material: material, hardMaterial: PhysicsMaterial(kind: .bubble, contactStiffness: 1e9))
            return await run(world, WorldTransaction().add(try bubble(1, at: [0, 0], radius: 2))).rejection == nil
        }
        // c = 7e34 jest skończone, c/dt² = 2,5e38 też, ale 2c/dt² = 5e38 przepełnia Float.
        let overflowsOnlyWithFactorTwo = try await accepts(base: 3.5e34)
        XCTAssertFalse(overflowsOnlyWithFactorTwo, "2c/dt² przepełnia Float")
        let fitsWithFactorTwo = try await accepts(base: 2e34)
        XCTAssertTrue(fitsWithFactorTwo, "2c/dt² = 2,9e38 mieści się w Float")
    }

    // Przejście promienia, które już trwa, wchodzi do przedziału: stan końcowy przepełnia α także wtedy, gdy bieżący promień jest mały.
    func testWorstAlphaIncludesTheScheduledEndOfARunningRadiusTransition() async throws {
        let world = try await transactionWorld(material: overflowing(), hardMaterial: hardWithoutCompliance()) {
            $0.add(try bubble(1, at: [0, 0], radius: 1))
        }
        // Wolne przejście do r = 2 (c = 4e34, α = 2,9e38 mieści się w Float przy r_ref = 1): trwa przez cały test.
        assertAccepted(await run(world, WorldTransaction().startTransition(
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(2), duration: 5))), "startTransition do r = 2")
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        // r_ref = 0,5: bieżący promień 1 daje c = 4e34 (α = 2,9e38, skończone), ale cel przejścia r = 2 daje c = 8e34 (α = 5,8e38),
        // więc dopiero przedział z celem przejścia odrzuca aktualizację materiału.
        assertRejected(await run(world, WorldTransaction().updatePhysicsMaterial(soft,
            material: try CrowdScene.softBubblePhysics(base: 2e34, referenceRadius: 0.5))), at: 0, reason,
            "updatePhysicsMaterial z celem przejścia r = 2")
        // Bez przejścia ten sam materiał dla bańki r = 1 jest przyjęty: c = 4e34.
        let calm = try await transactionWorld(material: overflowing(), hardMaterial: hardWithoutCompliance()) {
            $0.add(try bubble(1, at: [0, 0], radius: 1))
        }
        assertAccepted(await run(calm, WorldTransaction().updatePhysicsMaterial(soft,
            material: try CrowdScene.softBubblePhysics(base: 2e34, referenceRadius: 0.5))), "updatePhysicsMaterial bez przejścia")
    }

    // P-B-20 (G3-AC9): `startTransition` promienia po przepełnieniu odrzucone; promień bez zmian.
    func testWorstAlphaRejectsRadiusTransitionThatOverflowsAndKeepsTheRadius() async throws {
        let world = try await transactionWorld(material: overflowing(), hardMaterial: hardWithoutCompliance()) {
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
        let moderate = try CrowdScene.softBubblePhysics(base: 1e-3, referenceRadius: 20)
        let world = try await transactionWorld(material: moderate, hardMaterial: hardWithoutCompliance()) {
            $0.add(try bubble(1, at: [0, 0], radius: 4))
        }
        let reason = TransactionRejectionReason.invalidValue(.valueOutOfRange("contactCompliance"))
        // Z c₀ = 2e34 i r_ref = 1 bańka r = 4 ma c = 8e34 (α = 5,8e38): stan po aktualizacji przepełnia Float.
        assertRejected(await run(world, WorldTransaction().updatePhysicsMaterial(soft, material: try overflowing())), at: 0, reason,
                       "updatePhysicsMaterial")
        // Materiał nie zmienił się: nowa bańka r = 4 na nim przechodzi, a gdyby zmieniono, byłaby odrzucona.
        assertAccepted(await run(world, WorldTransaction().add(try bubble(2, at: [100, 100], radius: 4))),
                       "add na niezmienionym materiale")
        // Materiał, po którym α jest skończone, jest przyjęty.
        assertAccepted(await run(world, WorldTransaction().updatePhysicsMaterial(soft,
            material: try CrowdScene.softBubblePhysics(base: 2e-3, referenceRadius: 20))), "updatePhysicsMaterial skończone")
    }

    // MARK: prawo promienia (P-B-21 – P-B-24)

    private func twoRadii(material: PhysicsMaterial, steps: Int = 120) async throws -> [UInt64: [Float]] {
        let world = try await pressWorld(material: material) {
            var t = try CrowdScene.pressedBubble($0, 1, y: -200, radius: 20, force: self.force)
            t = try CrowdScene.pressedBubble(t, 2, y: 200, radius: 40, force: self.force)
            return t
        }
        return await CrowdScene.wallPress(world: world, [(1, 20, .left), (2, 40, .left)], steps: steps)
    }

    // P-B-21 – P-B-24: c = c₀ · r / r_ref daje równe względne wgniecenie δ / r i uspokojone δ.
    func testRadiusLawGivesEqualRelativeDent() async throws {
        let series = try await twoRadii(material: CrowdScene.softBubblePhysics(base: base))
        let small = try finalDepth(series, 1) / 20, large = try finalDepth(series, 2) / 40
        XCTAssertGreaterThan(small, 0.01, "bańka r = 20 uginała się: δ/r = \(small)")
        XCTAssertEqual(large, small, accuracy: 0.02 * small, "równe δ/r, jest \(small) i \(large)")
        try assertSettled(series, 1, radius: 20, "r = 20")
        try assertSettled(series, 2, radius: 40, "r = 40")
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

    // P-B-23 (G4-AC3): podwojona siła daje 2× ugięcia, bo c nie zależy od ściśnięcia.
    func testDoubledForceDoublesTheDent() async throws {
        let result = try await doubledForce(material: CrowdScene.softBubblePhysics(base: base))
        XCTAssertGreaterThan(result.single, 0.01, "bańka uginała się: δ/r = \(result.single)")
        XCTAssertEqual(result.doubled / result.single, 2, accuracy: 0.04, "δ/r \(result.single) → \(result.doubled)")
        try assertSettled(result.series, 1, radius: 20, "F")
        try assertSettled(result.series, 2, radius: 20, "2F")
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

    /// Promień efektywny bańki 1 i 2 po `steps` krokach sceny, w której bańka 2 (materiał `second`) pcha bańkę 1 (materiał `first`) w ścianę.
    private func pushedAgainstWall(first: PhysicsMaterial, second: PhysicsMaterial) async throws -> (first: ObjectState, second: ObjectState) {
        let world = try await CrowdScene.makeWorld(bubble: first) { setup in
            setup.updatePhysicsMaterial(CrowdScene.secondBubbleMaterial, material: second)
                .add(try CrowdScene.bubble(1, at: [-160, 0], radius: 20))
                .add(try CrowdScene.bubble(2, at: [-120, 0], radius: 20, material: CrowdScene.secondBubbleMaterial))
                .setMotorDrive(self.id(2), drive: try MotorDrive(force: [-self.force, 0]))
        }
        var frame = await world.advance(by: step)
        for _ in 0..<steps { frame = await world.advance(by: step) }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        return (try XCTUnwrap(frame.objects[id(1)]), try XCTUnwrap(frame.objects[id(2)]))
    }

    // P-B-25 (G4-AC4) dla konturu: materiał z domyślnym `deformability` = 0 omija bramkę deformowalności tylko przy c > 0, więc miękka
    // bańka przy ścianie ma kontur ścięty ścianą (promień efektywny < docelowy), a twarda o tym samym `deformability` go nie ma.
    func testHardAgainstSoftContourCutsOnlyTheSoftBubbleAtTheWall() async throws {
        let soft = try CrowdScene.softBubblePhysics(base: base), hard = try CrowdScene.softBubblePhysics(base: 0)
        let softPressed = try await pushedAgainstWall(first: soft, second: hard)
        let hardPressed = try await pushedAgainstWall(first: hard, second: hard)
        let softRadius = CrowdScene.effectiveRadius(of: softPressed.first)
        XCTAssertLessThan(softRadius, 20 - 0.3, "miękka bańka przy ścianie ma kontur ścięty ścianą, promień efektywny \(softRadius)")
        XCTAssertEqual(CrowdScene.effectiveRadius(of: hardPressed.first), 20, accuracy: 0.01,
                       "twarda bańka z `deformability` = 0 nie ma konturu także przy tej samej scenie")
        XCTAssertEqual(CrowdScene.effectiveRadius(of: softPressed.second), 20, accuracy: 0.2, "twarda pchająca bez wgniecenia")
    }

    // CD-D-12: w parze miękkiej bańka o c = 0 nie dostaje wgniecenia, nawet gdy jej materiał jest deformowalny (`deformability` > 0).
    func testHardDeformableBubbleGetsNoDentFromASoftPair() async throws {
        let soft = try CrowdScene.softBubblePhysics(base: pairBase)
        let hardDeformable = try PhysicsMaterial(kind: .bubble, contactStiffness: 1e9)
        let pressed = try await pushedAgainstWall(first: soft, second: hardDeformable)
        XCTAssertEqual(CrowdScene.effectiveRadius(of: pressed.second), 20, accuracy: 0.2,
                       "twarda deformowalna bańka w parze miękkiej zachowuje promień, jest \(CrowdScene.effectiveRadius(of: pressed.second))")
        XCTAssertLessThan(simd.distance(pressed.first.position, pressed.second.position), 40 - 0.3, "miękka ustępuje")
    }

    private func finalDepths(_ values: [UInt64: [Float]], _ ids: [UInt64]) throws -> [Float] {
        try ids.map { try finalDepth(values, $0) }
    }

    // MARK: model 3.0.0: c = c₀ · r / r_ref (P-B-1, P-B-2)

    /// c₀ i r_ref z kryteriów G3-AC1 i G3-AC2. Materiał z samych `base` i `referenceRadius`: ugięcie ma wynikać z modelu c₀ · r / r_ref,
    /// a nie z pomocnika `softBubblePhysics`.
    private let modelBase: Float = 0.0108
    private let modelReferenceRadius: Float = 20

    private func modelMaterial(deformability: Float = 0) throws -> PhysicsMaterial {
        try PhysicsMaterial(kind: .bubble, contactStiffness: modelReferenceRadius / modelBase)
    }

    /// Ściana statyczna o grubości 300 (co najmniej 2r także dla r = 148), czoło w x = −100, w świecie bez ram `CrowdScene`.
    private func thickWallWorld(_ build: (WorldTransaction) throws -> WorldTransaction) async throws -> BubbleWorld {
        try await modelWorld(withWall: true, build)
    }

    /// Świat ±500 bez żadnych ścian ani ram: nic poza polami sceny nie działa na bańki (P-B-2: para ściskana bez ścian).
    private func openWorld(_ build: (WorldTransaction) throws -> WorldTransaction) async throws -> BubbleWorld {
        try await modelWorld(withWall: false, build)
    }

    private func modelWorld(withWall: Bool, _ build: (WorldTransaction) throws -> WorldTransaction) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-500, -500], max: [500, 500]), fixedTimeStep: CrowdScene.step, eventBufferCapacity: 4096))
        let wall = WorldObject.rigidBody(try RigidBodyDescriptor(id: CrowdScene.wallIDs[0],
            vertices: [[-400, -450], [-100, -450], [-100, 450], [-400, 450]], motionRole: .static,
            physicsMaterialID: CrowdScene.wallMaterial, renderMaterialID: CrowdScene.style))
        let resources = try CrowdScene.resources(bubble: modelMaterial())
        _ = world.submit(try build(withWall ? resources.add(wall) : resources))
        let frame = await world.advance(by: CrowdScene.step)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "przygotowanie sceny")
        XCTAssertEqual(frame.transactionReceipts.count, 1, "przygotowanie sceny musi zostać przyjęte")
        return world
    }

    // P-B-1 (G3-AC1): ta sama siła ściska każdą bańkę o ten sam ułamek promienia, ε = δ / r = c₀ · F / r_ref, także gdy ε · r
    // przekracza grubość ściany ram (r = 148, δ ≈ 48).
    func testRelativeDeflectionIsTheSameForEveryRadius() async throws {
        let radii: [(id: UInt64, radius: Float, y: Float)] = [(1, 12, 120), (2, 24, 40), (3, 48, -60), (4, 148, -300)]
        let pressForce: Float = 600
        let world = try await thickWallWorld { setup in
            try radii.reduce(setup) { transaction, bubble in
                transaction
                    .add(try CrowdScene.bubble(bubble.id, at: [-100 + bubble.radius, bubble.y], radius: bubble.radius))
                    .setMotorDrive(CrowdScene.id(bubble.id), drive: try MotorDrive(force: [-pressForce, 0]))
            }
        }
        var frame = await world.advance(by: CrowdScene.step)
        var tail: [UInt64: [Float]] = [:]
        for index in 0..<900 {
            frame = await world.advance(by: CrowdScene.step)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index): \(String(describing: world.diagnostics.lastRejectionReason))")
            guard index >= 840 else { continue }
            for bubble in radii {
                let state = try XCTUnwrap(frame.objects[CrowdScene.id(bubble.id)])
                tail[bubble.id, default: []].append((bubble.radius - (state.position.x + 100)) / bubble.radius)
            }
        }
        let expected = modelBase * pressForce / modelReferenceRadius
        for bubble in radii {
            let series = try XCTUnwrap(tail[bubble.id])
            let last = try XCTUnwrap(series.last)
            XCTAssertEqual(last, expected, accuracy: 0.02 * expected, "r = \(bubble.radius): ε = \(last), oczekiwane c₀ · F / r_ref = \(expected)")
            XCTAssertLessThan((series.max() ?? 0) - (series.min() ?? 0), 0.005 * expected, "r = \(bubble.radius): ε ma być uspokojone")
        }
    }

    // P-B-2 (G3-AC2): para z jednego materiału, ściskana dwoma polami kierunkowymi wzdłuż osi. Nakładanie to (c_a + c_b) · F,
    // a wgniecenie konturu każdej bańki dzieli je w proporcji promieni: nakładanie · r_self / (r_a + r_b).
    func testSoftPairOverlapIsTheSumOfCompliancesAndDentsSplitByRadius() async throws {
        let pressForce: Float = 600
        for (radiusA, radiusB) in [(Float(12), Float(24)), (24, 24), (24, 148)] {
            let overlap = modelBase * pressForce * (radiusA + radiusB) / modelReferenceRadius
            let distance = radiusA + radiusB - overlap
            func field(_ value: UInt64, target: UInt64, direction: Float) throws -> WorldObject {
                .forceField(try ForceFieldDescriptor(id: CrowdScene.id(value), position: .zero,
                    geometry: RangeGeometry(shape: .circle(radius: 200)), field: .directional(force: [direction * pressForce, 0]),
                    filter: ObjectFilter(objectIDs: [CrowdScene.id(target)])))
            }
            let world = try await openWorld { setup in
                setup.add(try CrowdScene.bubble(1, at: [-distance / 2, 0], radius: radiusA))
                    .add(try CrowdScene.bubble(2, at: [distance / 2, 0], radius: radiusB))
                    .add(try field(500, target: 1, direction: 1)).add(try field(501, target: 2, direction: -1))
            }
            var frame = await world.advance(by: CrowdScene.step)
            var tail: [Float] = []
            for index in 0..<600 {
                frame = await world.advance(by: CrowdScene.step)
                guard index >= 540 else { continue }
                tail.append(simd_distance(try XCTUnwrap(frame.objects[CrowdScene.id(1)]).position,
                                          try XCTUnwrap(frame.objects[CrowdScene.id(2)]).position))
            }
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "(\(radiusA), \(radiusB))")
            let first = try XCTUnwrap(frame.objects[CrowdScene.id(1)]), second = try XCTUnwrap(frame.objects[CrowdScene.id(2)])
            XCTAssertLessThan((tail.max() ?? 0) - (tail.min() ?? 0), 0.005 * overlap,
                              "(\(radiusA), \(radiusB)): nakładanie ma być uspokojone w ostatnich 60 krokach")
            let measuredOverlap = radiusA + radiusB - simd_distance(first.position, second.position)
            XCTAssertEqual(measuredOverlap, overlap, accuracy: 0.02 * overlap,
                           "(\(radiusA), \(radiusB)): nakładanie \(measuredOverlap), oczekiwane (c_a + c_b) · F = \(overlap)")
            let dentA = radiusA - CrowdScene.effectiveRadius(of: first), dentB = radiusB - CrowdScene.effectiveRadius(of: second)
            let expectedA = overlap * radiusA / (radiusA + radiusB), expectedB = overlap * radiusB / (radiusA + radiusB)
            XCTAssertEqual(dentA, expectedA, accuracy: 0.02 * expectedA, "(\(radiusA), \(radiusB)): wgniecenie a \(dentA), oczekiwane \(expectedA)")
            XCTAssertEqual(dentB, expectedB, accuracy: 0.02 * expectedB, "(\(radiusA), \(radiusB)): wgniecenie b \(dentB), oczekiwane \(expectedB)")
        }
    }
}
