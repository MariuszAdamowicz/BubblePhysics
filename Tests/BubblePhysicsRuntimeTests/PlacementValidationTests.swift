@testable import BubblePhysics
import BubblePhysicsNativeMetal
@testable import BubblePhysicsRuntime
import Metal
import simd
import XCTest

/// Walidacja punktu bańki w transakcji (P-B-1 – P-B-8): zły punkt `add` i `replace` odrzuca transakcję,
/// a `mergeBubbles` i `splitBubble` same poprawiają punkt wyniku albo odrzucają transakcję, gdy poprawnego nie ma.
/// Zdarzenia i przyjęcie kroku sprawdza publiczny `BubbleWorld`, dokładne środki wyników stager (CPU).
@MainActor
final class PlacementValidationTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderMaterialID(rawValue: 1)
    private let step = 1.0 / 60

    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func configuration() throws -> WorldConfiguration {
        try WorldConfiguration(simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100]), fixedTimeStep: step)
    }
    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(rigidMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial())
    }
    private func bubble(_ value: UInt64, at position: WorldPoint, radius: Float = 2, velocity: WorldPoint = .zero,
                        policy: RegionExitPolicy = .remove) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, velocity: velocity, targetRadius: radius,
                                     mass: 2, regionExitPolicy: policy, physicsMaterialID: bubbleMaterial,
                                     renderMaterialID: style, eventInterest: [.didAdd]))
    }
    private func result(_ value: UInt64) -> BubbleResult {
        BubbleResult(id: id(value), physicsMaterialID: bubbleMaterial, renderMaterialID: style, eventInterest: [.didAdd])
    }
    private func body(_ value: UInt64, _ shape: RigidShape, at position: WorldPoint = .zero,
                      role: MotionRole = .static) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), shape: shape, position: position, motionRole: role,
                                           physicsMaterialID: rigidMaterial, renderMaterialID: style))
    }
    private func rectangle(_ low: WorldPoint, _ high: WorldPoint) throws -> RigidShape {
        .polygon(try PolygonGeometry(vertices: [low, [high.x, low.y], high, [low.x, high.y]]))
    }

    // MARK: publiczny świat

    private func makeWorld(_ setup: (WorldTransaction) throws -> WorldTransaction = { $0 }) async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: configuration())
        _ = world.submit(try setup(resources()))
        let frame = await world.advance(by: step)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertEqual(frame.transactionReceipts.count, 1, "przygotowanie sceny musi zostać przyjęte")
        return world
    }
    /// Wysyła transakcję i robi jeden krok; zwraca klatkę i odrzucenie tej transakcji, jeśli było.
    private func run(_ world: BubbleWorld, _ transaction: WorldTransaction)
        async -> (frame: WorldFrame, token: TransactionToken, rejection: TransactionRejection?) {
        let token = world.submit(transaction)
        let frame = await world.advance(by: step)
        var found: TransactionRejection?
        for case .transactionRejected(let rejected, let rejection) in frame.events where rejected == token { found = rejection }
        return (frame, token, found)
    }
    private func assertRejected(_ outcome: (frame: WorldFrame, token: TransactionToken, rejection: TransactionRejection?),
                                at index: Int, _ reason: TransactionRejectionReason,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(outcome.rejection, TransactionRejection(operationIndex: index, reason: reason), file: file, line: line)
        XCTAssertFalse(outcome.frame.transactionReceipts.contains { $0.token == outcome.token }, file: file, line: line)
    }
    /// Świat idzie dalej: następna transakcja z poprawnym punktem jest przyjęta.
    private func assertNextStepAccepted(_ world: BubbleWorld, file: StaticString = #filePath, line: UInt = #line) async throws {
        let outcome = await run(world, WorldTransaction().add(try bubble(900, at: [60, 60])))
        XCTAssertNil(outcome.rejection, file: file, line: line)
        XCTAssertEqual(outcome.frame.transactionReceipts.last?.createdObjectIDs, [id(900)], file: file, line: line)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, file: file, line: line)
    }

    // MARK: stager (CPU)

    private func staged(_ transactions: [WorldTransaction]) throws -> RuntimeState {
        var state = RuntimeState(configuration: try configuration())
        for transaction in transactions { state = try TransactionStager.stage(transaction, against: state).state }
        return state
    }
    private func stage(_ transaction: WorldTransaction, against state: RuntimeState) throws -> RuntimeState {
        try TransactionStager.stage(transaction, against: state).state
    }

    // MARK: add

    // P-B-1
    func testAddWithCoincidentCenterIsRejectedAndNextStepAccepted() async throws {
        let world = try await makeWorld { $0.add(try self.bubble(1, at: [10, 10])) }
        let outcome = await run(world, WorldTransaction().add(try bubble(2, at: [10, 10], radius: 5)))
        assertRejected(outcome, at: 0, .invalidPlacement(id(2), .coincidentCenter))
        XCTAssertNil(outcome.frame.objects[id(2)])
        XCTAssertNotNil(outcome.frame.objects[id(1)])
        try await assertNextStepAccepted(world)
    }

    func testAddJustInsideCoincidentToleranceIsRejectedAndJustOutsideIsAccepted() async throws {
        let state = try staged([resources().add(bubble(1, at: [10, 10]))])
        // Tolerancja to max(1e-4 · r mniejszej, 1e-4) = 2e-4 dla r = 2.
        XCTAssertThrowsError(try stage(WorldTransaction().add(bubble(2, at: [10.0001, 10])), against: state)) {
            XCTAssertEqual(($0 as? TransactionRejection)?.reason, .invalidPlacement(self.id(2), .coincidentCenter))
        }
        XCTAssertNoThrow(try stage(WorldTransaction().add(bubble(2, at: [10.01, 10])), against: state))
    }

    /// F-2: tolerancja wspólnego środka idzie ze steppera (jak `baseContactCompliance`), a nie z domyślnej konfiguracji solvera.
    /// Dla r = 2 część względna to 2e-4; odstęp 0,005 jest powyżej domyślnej tolerancji solvera (1e-4) i poniżej 0,01.
    func testCoincidentCenterToleranceComesFromTheStepper() async throws {
        func addNear(positionTolerance: Float) async throws -> TransactionRejection? {
            let world = BubbleWorld(configuration: try configuration(),
                                    stepper: PositionToleranceStepper(positionTolerance: positionTolerance))
            _ = world.submit(try resources().add(bubble(1, at: [10, 10])))
            let setup = await world.advance(by: step)
            XCTAssertEqual(setup.transactionReceipts.count, 1, "przygotowanie sceny musi zostać przyjęte")
            return await run(world, WorldTransaction().add(try bubble(2, at: [10.005, 10]))).rejection
        }
        let wide = try await addNear(positionTolerance: 0.01)
        XCTAssertEqual(wide, TransactionRejection(operationIndex: 0, reason: .invalidPlacement(id(2), .coincidentCenter)))
        let narrow = try await addNear(positionTolerance: 1e-4)
        XCTAssertNil(narrow)

        let state = try staged([resources().add(bubble(1, at: [10, 10]))])
        XCTAssertThrowsError(try TransactionStager.stage(WorldTransaction().add(bubble(2, at: [10.005, 10])), against: state,
                                                         positionTolerance: 0.01))
        XCTAssertNoThrow(try stage(WorldTransaction().add(bubble(2, at: [10.005, 10])), against: state))
    }

    /// Natywny stepper podaje tolerancję, z którą `NativePublicWorld` buduje konfigurację solvera; domyślna w protokole to 1e-4.
    func testNativeStepperExposesTheSolverPositionTolerance() throws {
        XCTAssertEqual(try NativeCompleteStepper(device: nil).positionTolerance, NativePublicWorld.positionTolerance)
        XCTAssertEqual(NativePublicWorld.positionTolerance, 1e-4)
        XCTAssertEqual(PositionToleranceStepper.protocolDefault, 1e-4)
    }

    func testAddCoincidentWithBubbleCreatedEarlierInTheSameTransactionIsRejected() throws {
        let state = try staged([resources()])
        XCTAssertThrowsError(try stage(WorldTransaction().add(bubble(1, at: [5, 5])).add(bubble(2, at: [5, 5])),
                                       against: state)) {
            XCTAssertEqual($0 as? TransactionRejection,
                           TransactionRejection(operationIndex: 1, reason: .invalidPlacement(self.id(2), .coincidentCenter)))
        }
    }

    // P-B-2
    func testAddInsideRigidBodyIsRejectedForPolygonCircleAndCapsule() async throws {
        let cases: [(RigidShape, WorldPoint, WorldPoint)] = [
            (try rectangle([-20, -20], [20, 20]), .zero, [5, 5]),
            (.circle(radius: 15), [50, 0], [55, 4]),
            (.capsule(halfLength: 10, radius: 4), [0, -50], [8, -52])]
        for (index, (shape, position, inside)) in cases.enumerated() {
            let world = try await makeWorld { $0.add(try self.body(100 + UInt64(index), shape, at: position)) }
            let outcome = await run(world, WorldTransaction().add(try bubble(2, at: inside)))
            assertRejected(outcome, at: 0, .invalidPlacement(id(2), .insideRigidBody))
            try await assertNextStepAccepted(world)
        }
    }

    func testAddOutsideRegionIsRejectedAlsoWithWrapPolicy() async throws {
        for policy: RegionExitPolicy in [.remove, .wrap] {
            let world = try await makeWorld()
            for point: WorldPoint in [[100.5, 0], [0, -101], [-300, 300]] {
                let outcome = await run(world, WorldTransaction().add(try bubble(2, at: point, policy: policy)))
                assertRejected(outcome, at: 0, .invalidPlacement(id(2), .outsideRegion))
            }
            try await assertNextStepAccepted(world)
        }
    }

    func testAddReportsRegionBeforeRigidBodyBeforeCoincidentCenter() throws {
        // Dynamiczna bryła może wystawać poza region; bańka 1 stoi w jej wnętrzu.
        let state = try staged([resources()
            .add(bubble(1, at: [0, 0]))
            .add(body(10, rectangle([-10, -10], [150, 10]), role: .dynamic))])
        func reason(_ point: WorldPoint) -> TransactionRejectionReason? {
            do { _ = try stage(WorldTransaction().add(bubble(2, at: point)), against: state); return nil }
            catch let rejection as TransactionRejection { return rejection.reason }
            catch { return nil }
        }
        XCTAssertEqual(reason([120, 0]), .invalidPlacement(id(2), .outsideRegion), "region wygrywa z bryłą")
        XCTAssertEqual(reason([0, 0]), .invalidPlacement(id(2), .insideRigidBody), "bryła wygrywa ze wspólnym środkiem")
        XCTAssertNil(reason([0, 30]))
    }

    // P-B-3
    func testReplaceAtBadPlacementIsRejectedWithTheSameCauses() async throws {
        let world = try await makeWorld {
            $0.add(try self.bubble(1, at: [-30, 0])).add(try self.bubble(2, at: [30, 0]))
                .add(try self.body(100, try self.rectangle([-5, 40], [5, 50])))
        }
        let cases: [(WorldPoint, PlacementIssue)] = [([30, 0], .coincidentCenter), ([0, 45], .insideRigidBody),
                                                     ([150, 0], .outsideRegion)]
        for (point, issue) in cases {
            let outcome = await run(world, WorldTransaction().replace(id(1), with: try bubble(1, at: point)))
            assertRejected(outcome, at: 0, .invalidPlacement(id(1), issue))
            XCTAssertEqual(outcome.frame.objects[id(1)]?.position, [-30, 0], "zastępowana bańka zostaje")
        }
        try await assertNextStepAccepted(world)
    }

    func testReplaceExcludesTheReplacedBubbleFromTheCoincidentTest() async throws {
        let world = try await makeWorld { $0.add(try self.bubble(1, at: [10, 10])) }
        let outcome = await run(world, WorldTransaction().replace(id(1), with: try bubble(1, at: [10, 10], radius: 5)))
        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.frame.transactionReceipts.last?.replacedObjectIDs, [id(1)])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    // P-B-4
    func testValidPlacementsAreAcceptedIncludingBubblePartiallyOverlappingAnother() async throws {
        let world = try await makeWorld { $0.add(try self.bubble(1, at: [0, 0], radius: 10)) }
        let outcome = await run(world, WorldTransaction()
            .add(try bubble(2, at: [12, 0], radius: 5))       // nachodzi na bańkę 1
            .add(try bubble(3, at: [-30, 0.01], radius: 2))
            .add(try bubble(4, at: [-30, 0.02], radius: 2))) // środki o 0,01 od siebie, ponad tolerancją
        XCTAssertNil(outcome.rejection)
        XCTAssertEqual(outcome.frame.transactionReceipts.last?.createdObjectIDs, [id(2), id(3), id(4)])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    // Obiekty, których filtry się wykluczają, nigdy nie kolidują, więc wspólny środek ani punkt w bryle nie jest dla nich błędem.
    private let ghost = CollisionFilter(category: 2, mask: 0)
    private func ghostBubble(_ value: UInt64, at position: WorldPoint) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, targetRadius: 2, mass: 2,
                                     physicsMaterialID: bubbleMaterial, renderMaterialID: style, filter: ghost))
    }

    /// F-7: przeciążenie `issue` z gotową listą brył (budowaną raz na scalenie lub podział) daje te same przyczyny co
    /// dotychczasowa sygnatura: region, bryła (wielokąt obrócony, koło, kapsuła), filtr kolizji, wyłączenie z testu, wspólny środek.
    func testIssueWithPrebuiltRigidBodiesGivesTheSameCausesAsTheStateScan() throws {
        var rotated = RuntimeObject(try body(101, rectangle([-4, -1], [4, 1]), at: [20, 0]))
        rotated.rotation = .pi / 2
        let state0 = try staged([resources().add(bubble(1, at: [0, 30]))
            .add(body(100, rectangle([-60, -60], [-40, -40])))
            .add(body(102, .circle(radius: 3), at: [0, -20]))
            .add(body(103, .capsule(halfLength: 5, radius: 1), at: [30, 30]))
            .add(.rigidBody(try RigidBodyDescriptor(id: id(104), shape: .circle(radius: 3), position: [-20, 0],
                                                    physicsMaterialID: rigidMaterial, renderMaterialID: style, filter: ghost)))])
        var state = state0
        state.objects[id(101)] = rotated
        let bodies = PlacementGeometry.rigidBodies(in: state)
        let cases: [(WorldPoint, Set<ObjectID>, CollisionFilter, PlacementIssue?)] = [
            ([200, 0], [], .default, .outsideRegion),
            ([-50, -50], [], .default, .insideRigidBody),
            ([-50, -50], [id(100)], .default, nil),
            ([-50, -50], [], ghost, nil),
            ([20, 3.5], [], .default, .insideRigidBody),
            ([23.5, 0], [], .default, nil),
            ([0, -18], [], .default, .insideRigidBody),
            ([34, 30.5], [], .default, .insideRigidBody),
            ([-20, 0], [], .default, nil),
            ([0, 30], [], .default, .coincidentCenter),
            ([0, 30], [id(1)], .default, nil),
            ([0, 30.005], [], .default, nil),
        ]
        for (point, excluding, filter, expected) in cases {
            XCTAssertEqual(PlacementGeometry.issue(at: point, radius: 2, filter: filter, in: state, excluding: excluding), expected,
                           "skan stanu, punkt \(point)")
            XCTAssertEqual(PlacementGeometry.issue(at: point, radius: 2, filter: filter, in: state, excluding: excluding,
                                                   rigidBodies: bodies), expected, "gotowa lista brył, punkt \(point)")
        }
        XCTAssertEqual(Set(bodies.map(\.id)), [id(100), id(101), id(102), id(103), id(104)], "lista ma tylko bryły")
    }

    func testAddIgnoresBubblesAndBodiesWhoseCollisionFilterExcludesTheNewBubble() throws {
        let state = try staged([resources().add(bubble(1, at: [10, 10]))
            .add(body(100, rectangle([-60, -60], [-40, -40])))])
        XCTAssertNoThrow(try stage(WorldTransaction().add(ghostBubble(2, at: [10, 10])), against: state),
                         "bańka bez kolizji z bańką 1 może stanąć w jej środku")
        XCTAssertNoThrow(try stage(WorldTransaction().add(ghostBubble(2, at: [-50, -50])), against: state),
                         "bańka bez kolizji z bryłą może stanąć w jej wnętrzu")
        XCTAssertNoThrow(try stage(WorldTransaction().add(ghostBubble(2, at: [0, 0])).add(ghostBubble(3, at: [0, 0])),
                                   against: state), "dwie bańki duchy w jednym punkcie")
        XCTAssertNoThrow(try stage(WorldTransaction().add(ghostBubble(2, at: [30, 30]))
            .replace(id(2), with: ghostBubble(2, at: [10, 10])), against: state), "replace na środku bańki bez kolizji")
        // Region obowiązuje niezależnie od filtra.
        XCTAssertThrowsError(try stage(WorldTransaction().add(ghostBubble(2, at: [150, 0])), against: state)) {
            XCTAssertEqual(($0 as? TransactionRejection)?.reason, .invalidPlacement(self.id(2), .outsideRegion))
        }
    }

    func testMergeResultIgnoresBubblesWhoseCollisionFilterExcludesTheResult() throws {
        // Punkt styku (0, 0) to środek bańki 3; wynik z filtrem, który jej nie dotyka, stoi w punkcie styku.
        let state = try staged([resources().add(bubble(1, at: [-10, 0])).add(bubble(2, at: [10, 0])).add(bubble(3, at: [0, 0]))])
        let result = BubbleResult(id: id(4), physicsMaterialID: bubbleMaterial, renderMaterialID: style, filter: ghost)
        let after = try stage(WorldTransaction().mergeBubbles([id(1), id(2)], result: result), against: state)
        XCTAssertEqual(try XCTUnwrap(after.objects[id(4)]).position, [0, 0])
    }

    func testValidAddAtRegionEdgeIsAccepted() throws {
        let state = try staged([resources()])
        XCTAssertNoThrow(try stage(WorldTransaction().add(bubble(1, at: [100, 100])), against: state))
    }

    // MARK: merge

    private func mergeCenter(_ state: RuntimeState, sources: [UInt64], result: UInt64) throws -> WorldPoint {
        let after = try stage(WorldTransaction().mergeBubbles(sources.map(id), result: self.result(result)), against: state)
        return try XCTUnwrap(after.objects[id(result)]).position
    }

    // P-B-5
    func testMergeWithContactInsideThirdBubbleStandsAtTheFirstSourceCandidate() async throws {
        let setup = try resources().add(bubble(1, at: [-10, 0])).add(bubble(2, at: [10, 0])).add(bubble(3, at: [0, 0]))
        let state = try staged([setup])
        // Punkt styku to (0, 0), czyli środek bańki 3; pierwszy kandydat to P + 0,25 · (S₁ − P).
        let center = try mergeCenter(state, sources: [1, 2], result: 4)
        XCTAssertEqual(center, [-2.5, 0])
        XCTAssertEqual(try mergeCenter(state, sources: [1, 2], result: 4), center, "ten sam układ daje ten sam środek")
        XCTAssertEqual(try mergeCenter(state, sources: [2, 1], result: 4), center, "kolejność sources w transakcji nie zmienia środka")

        let world = try await makeWorld { _ in setup }
        let outcome = await run(world, WorldTransaction().mergeBubbles([id(1), id(2)], result: result(4)))
        XCTAssertNil(outcome.rejection)
        XCTAssertTrue(outcome.frame.events.contains(.didAdd(id(4))))
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    /// Scalenie [1, 2] -> 4 w dwóch osobnych światach (źródła podane w kolejności 1, 2 i 2, 1): środek wyniku w pierwszej
    /// klatce leży w regionie, poza bryłami, nie pokrywa się z innymi bańkami i jest taki sam w obu światach (G3-AC4).
    /// `others` to inne bańki z ich promieniami.
    private func assertMergeInPublicWorld(resultRadius: Float, bodies: [WorldObject], others: [(UInt64, Float)],
                                          setup: (WorldTransaction) throws -> WorldTransaction,
                                          beforeMerge: (WorldTransaction) throws -> WorldTransaction = { $0 },
                                          file: StaticString = #filePath, line: UInt = #line) async throws {
        var centers: [WorldPoint] = []
        for sources in [[id(1), id(2)], [id(2), id(1)]] {
            let world = try await makeWorld(setup)
            let outcome = await run(world, try beforeMerge(WorldTransaction()).mergeBubbles(sources, result: result(4)))
            XCTAssertNil(outcome.rejection, file: file, line: line)
            XCTAssertTrue(outcome.frame.events.contains(.didAdd(id(4))), file: file, line: line)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, file: file, line: line)
            let center = try XCTUnwrap(outcome.frame.objects[id(4)], file: file, line: line).position
            XCTAssertTrue(try configuration().simulationRegion.contains(center), "w regionie", file: file, line: line)
            for case .rigidBody(let descriptor) in bodies {
                XCTAssertFalse(PlacementGeometry.contains(
                    PlacementGeometry.shape(of: descriptor, at: RuntimeObject(.rigidBody(descriptor))), center),
                    "poza bryłą", file: file, line: line)
            }
            for (other, radius) in others {
                let position = try XCTUnwrap(outcome.frame.objects[id(other)], file: file, line: line).position
                XCTAssertGreaterThan(simd_distance(center, position),
                    PlacementGeometry.coincidentCenterTolerance(radius: resultRadius, otherRadius: radius),
                    "nie na środku bańki \(other)", file: file, line: line)
            }
            centers.append(center)
        }
        XCTAssertEqual(centers[0], centers[1], "ten sam układ daje ten sam środek niezależnie od świata i kolejności sources",
                       file: file, line: line)
    }

    // P-B-5 (świat publiczny)
    func testMergeInPublicWorldWithContactInsideThirdBubbleStandsAtAValidPoint() async throws {
        try await assertMergeInPublicWorld(resultRadius: Float(8).squareRoot(), bodies: [], others: [(3, 2)], setup: {
            try $0.add(self.bubble(1, at: [-10, 0])).add(self.bubble(2, at: [10, 0])).add(self.bubble(3, at: [0, 0]))
        })
    }

    func testMergeInPublicWorldWithContactInsideRigidBodyStandsOutsideTheBody() async throws {
        let wall = try body(100, rectangle([-1, -50], [1, 50]))
        try await assertMergeInPublicWorld(resultRadius: Float(8).squareRoot(), bodies: [wall], others: [], setup: {
            try $0.add(self.bubble(1, at: [-10, 0])).add(self.bubble(2, at: [10, 0])).add(wall)
        })
    }

    func testMergeInPublicWorldWithContactOutsideTheRegionStandsInsideTheRegion() async throws {
        // Punkt styku (103; 0) wypada poza regionem tylko dla pary, w której jedna bańka zawiera drugą, więc źródła
        // powstają w tej samej transakcji co scalenie, przed jakimkolwiek krokiem solvera.
        try await assertMergeInPublicWorld(resultRadius: Float(101).squareRoot(), bodies: [], others: [],
            setup: { $0 }, beforeMerge: {
                try $0.add(self.bubble(1, at: [98, 0], radius: 10)).add(self.bubble(2, at: [99, 0], radius: 1))
            })
    }

    func testMergeResultDoesNotCoincideWithAnyBubbleOrStandInsideABodyOrOutsideTheRegion() throws {
        // Punkt styku w bryle: ściana przy środku, źródła poza nią.
        let wall = try staged([resources().add(bubble(1, at: [-10, 0])).add(bubble(2, at: [10, 0]))
            .add(body(100, rectangle([-1, -50], [1, 50])))])
        XCTAssertEqual(try mergeCenter(wall, sources: [1, 2], result: 4), [-2.5, 0])
        // Punkt styku poza regionem: duża bańka przy krawędzi i mała tuż obok.
        let edge = try staged([resources().add(bubble(1, at: [98, 0], radius: 10)).add(bubble(2, at: [99, 0], radius: 1))])
        let center = try mergeCenter(edge, sources: [1, 2], result: 4)
        XCTAssertEqual(center, [99.25, 0])
        let region = try configuration().simulationRegion
        XCTAssertTrue(region.contains(center))
    }

    func testMergeFallsBackToTheSpiralAroundTheHeaviestSourceWhenEarlierCandidatesAreBlocked() throws {
        // Ściana przykrywa punkt styku, kandydatów pośrednich i oba środki źródeł; wolne jest dopiero trzecie okrążenie spirali.
        let state = try staged([resources().add(bubble(1, at: [-10, 0])).add(bubble(2, at: [10, 0]))])
        let wall = WorldTransaction().add(try body(100, rectangle([-12, -50], [12, 50])))
        let after = try stage(wall.mergeBubbles([id(1), id(2)], result: result(4)), against: state)
        let center = try XCTUnwrap(after.objects[id(4)]).position
        XCTAssertEqual(center.x, -10 - 3 * Float(8).squareRoot() / 4, accuracy: 1e-4)
        XCTAssertEqual(center.y, 0, accuracy: 1e-4)
    }

    func testMergeCandidateListHasThreeNPlusNPlus128PointsAndSpiralAroundTheHeaviestSource() throws {
        func source(_ value: UInt64, at x: Float, mass: Float) throws -> RuntimeObject {
            RuntimeObject(.bubble(try BubbleDescriptor(id: id(value), position: [x, 0], targetRadius: 2, mass: mass,
                physicsMaterialID: bubbleMaterial, renderMaterialID: style)))
        }
        let contact: WorldPoint = [0, 0]
        let equal = StructuralOperations.mergeCandidates(contact: contact,
            sources: [try source(1, at: -10, mass: 2), try source(2, at: 10, mass: 2)], resultRadius: 4)
        XCTAssertEqual(equal.count, 3 * 2 + 2 + 128)
        XCTAssertEqual(Array(equal[0..<3]), [[-2.5, 0], [-5, 0], [-7.5, 0]], "kandydaci pierwszego źródła")
        XCTAssertEqual(Array(equal[3..<6]), [[2.5, 0], [5, 0], [7.5, 0]], "kandydaci drugiego źródła")
        XCTAssertEqual(Array(equal[6..<8]), [[-10, 0], [10, 0]], "środki źródeł")
        // Przy równych masach spirala idzie wokół pierwszego źródła: pierścień j ma promień j, po 16 punktów.
        XCTAssertEqual(equal[8], [-9, 0])
        XCTAssertEqual(simd_distance(equal[8 + 16], [-10, 0]), 2, accuracy: 1e-4)
        XCTAssertEqual(simd_distance(equal[equal.count - 1], [-10, 0]), 8, accuracy: 1e-4)
        let weighted = StructuralOperations.mergeCandidates(contact: contact,
            sources: [try source(1, at: -10, mass: 1), try source(2, at: 10, mass: 5)], resultRadius: 4)
        XCTAssertEqual(weighted[8], [11, 0], "spirala wokół najcięższego źródła")
    }

    // P-B-6
    func testMergeWithoutAnyValidCandidateIsRejectedWithTheContactPointCause() async throws {
        let world = try await makeWorld { $0.add(try self.bubble(1, at: [-10, 0])).add(try self.bubble(2, at: [10, 0])) }
        let outcome = await run(world, WorldTransaction()
            .add(try body(100, try rectangle([-50, -50], [50, 50])))
            .mergeBubbles([id(1), id(2)], result: result(4)))
        assertRejected(outcome, at: 1, .invalidPlacement(id(4), .insideRigidBody))
        XCTAssertNotNil(outcome.frame.objects[id(1)])
        XCTAssertNotNil(outcome.frame.objects[id(2)])
        XCTAssertNil(outcome.frame.objects[id(4)])
        XCTAssertNil(outcome.frame.objects[id(100)], "odrzucona transakcja nie zostawia bryły")
        try await assertNextStepAccepted(world)
    }

    func testMergeRejectionReportsTheContactPointCauseNotTheLastCandidateCause() async throws {
        // Punkt styku (-100,5; 0) leży poza regionem, a wszyscy kandydaci w regionie, w tym ostatni punkt spirali,
        // przykrywa bryła: przyczyna z punktu styku to outsideRegion, z ostatniego kandydata insideRigidBody.
        // Taki punkt styku daje tylko para, w której jedna bańka zawiera drugą, więc źródła powstają w tej samej
        // transakcji co scalenie.
        let world = try await makeWorld()
        let outcome = await run(world, WorldTransaction()
            .add(try bubble(1, at: [-95, 0], radius: 8)).add(try bubble(2, at: [-99, 0], radius: 1))
            .add(try body(100, try rectangle([-100, -100], [100, 100])))
            .mergeBubbles([id(1), id(2)], result: result(4)))
        assertRejected(outcome, at: 3, .invalidPlacement(id(4), .outsideRegion))
        try await assertNextStepAccepted(world)
    }

    // MARK: split

    private func splitTransaction(after base: WorldTransaction = WorldTransaction(),
                                  first: UInt64 = 2, second: UInt64 = 3) -> WorldTransaction {
        base.splitBubble(id(1), first: BubbleSplitPart(result: result(first), share: 0.5),
                                       second: BubbleSplitPart(result: result(second), share: 0.5))
    }

    // P-B-7
    func testSplitAtWallPlacesPartsAtValidDistinctPointsAndKeepsMomentum() throws {
        var state = try staged([resources().add(bubble(1, at: [0, 0], radius: 10))])
        state.objects[id(1)]?.velocity = [3, 1]
        state.objects[id(1)]?.angularVelocity = 2
        // Ściana nachodzi na bańkę: centroid prawej części (4,24; 0) leży w bryle.
        let transaction = splitTransaction(after: WorldTransaction().add(try body(100, rectangle([3, -50], [60, 50]))))
        let after = try stage(transaction, against: state)
        let first = try XCTUnwrap(after.objects[id(2)]), second = try XCTUnwrap(after.objects[id(3)])
        XCTAssertEqual(first.position.x, -4.2441, accuracy: 1e-3, "lewy centroid jest poprawny i zostaje")
        XCTAssertEqual(second.position.x, 2.1221, accuracy: 1e-3, "kandydat t = 0,5 między centroidem a środkiem źródła")
        XCTAssertEqual(second.position.y, 0, accuracy: 1e-5)
        XCTAssertLessThan(second.position.x, 3, "poza bryłą")
        XCTAssertGreaterThan(simd_distance(first.position, second.position), 1e-3)
        XCTAssertEqual(first.previousPosition, first.position)
        XCTAssertEqual(second.previousPosition, second.position)
        XCTAssertEqual(second.structuralShape?.origin, second.position, "kształt strukturalny ma początek w końcowym środku")
        XCTAssertEqual(first.structuralShape?.origin, first.position)

        // Pęd liniowy i moment pędu względem środka masy części są zachowane mimo przesuniętego środka masy.
        let (m1, m2) = (Double(first.mass!), Double(second.mass!))
        let total = m1 + m2
        let momentum = SIMD2(m1 * Double(first.velocity.x) + m2 * Double(second.velocity.x),
                             m1 * Double(first.velocity.y) + m2 * Double(second.velocity.y))
        XCTAssertEqual(momentum.x, total * 3, accuracy: 1e-3)
        XCTAssertEqual(momentum.y, total * 1, accuracy: 1e-3)
        let com = SIMD2(m1 * Double(first.position.x) + m2 * Double(second.position.x),
                        m1 * Double(first.position.y) + m2 * Double(second.position.y)) / total
        func angular(_ part: RuntimeObject, _ mass: Double) -> Double {
            let r = SIMD2(Double(part.position.x), Double(part.position.y)) - com
            let radius = Double(part.targetRadius)
            return 0.5 * mass * radius * radius * Double(part.angularVelocity)
                + mass * (r.x * Double(part.velocity.y) - r.y * Double(part.velocity.x))
        }
        let source = try XCTUnwrap(state.objects[id(1)])
        let expected = 0.5 * Double(source.mass!) * 100 * 2
        XCTAssertEqual(angular(first, m1) + angular(second, m2), expected, accuracy: 1e-2)
    }

    func testSplitWithValidCentroidsKeepsThemAndDoesNotChangeVelocities() throws {
        var state = try staged([resources().add(bubble(1, at: [20, 0], radius: 10))])
        state.objects[id(1)]?.velocity = [3, 1]
        let after = try stage(splitTransaction(), against: state)
        let first = try XCTUnwrap(after.objects[id(2)]), second = try XCTUnwrap(after.objects[id(3)])
        XCTAssertEqual(first.position.x, 20 - 4.2441, accuracy: 1e-3)
        XCTAssertEqual(second.position.x, 20 + 4.2441, accuracy: 1e-3)
        XCTAssertEqual(first.velocity, [3, 1], "bez obrotu źródła obie części niosą prędkość źródła")
        XCTAssertEqual(second.velocity, [3, 1])
    }

    func testSplitSecondPartDoesNotCoincideWithTheCorrectedFirstPart() throws {
        let state = try staged([resources().add(bubble(1, at: [0, 0], radius: 10))])
        // Obie ściany przykrywają centroidy i kandydatów pośrednich, a wolny jest dopiero środek źródła.
        // Pierwsza część zajmuje go, więc druga musi pójść dalej, na pierwszy wolny punkt spirali.
        let walls = WorldTransaction().add(try body(100, rectangle([-60, -50], [-1, 50])))
            .add(try body(101, rectangle([1, -50], [60, 50])))
        let after = try stage(splitTransaction(after: walls), against: state)
        let first = try XCTUnwrap(after.objects[id(2)]), second = try XCTUnwrap(after.objects[id(3)])
        XCTAssertEqual(first.position, [0, 0])
        let step = 10 * Float(0.5).squareRoot() / 4
        XCTAssertEqual(second.position.x, step * cos(3 * Float.pi / 8), accuracy: 1e-4)
        XCTAssertEqual(second.position.y, step * sin(3 * Float.pi / 8), accuracy: 1e-4)
    }

    func testResolvedCentersTryTheDocumentedNumberOfCandidatesBeforeGivingUp() throws {
        var split = 0
        XCTAssertNil(StructuralOperations.resolvedSplitCenter(centroid: [1, 0], sourceCenter: .zero, partRadius: 4) { _ in
            split += 1; return .insideRigidBody
        })
        XCTAssertEqual(split, 1 + 3 + 1 + 128, "centroid, 3 punkty do środka źródła, środek źródła, spirala 8 × 16")
        let sources = try [UInt64(1), 2, 3].map { RuntimeObject(try bubble($0, at: [Float($0) * 10, 0])) }
        var merge = 0
        XCTAssertNil(StructuralOperations.resolvedMergeCenter(contact: .zero, sources: sources, resultRadius: 4) { _ in
            merge += 1; return .outsideRegion
        })
        XCTAssertEqual(merge, 1 + 3 * 3 + 3 + 128)
    }

    func testSplitAtWallInPublicWorldAddsBothPartsWithoutRejection() async throws {
        let world = try await makeWorld { $0.add(try self.bubble(1, at: [0, 0], radius: 10)) }
        let outcome = await run(world, splitTransaction(
            after: WorldTransaction().add(try body(100, try rectangle([3, -50], [60, 50])))))
        XCTAssertNil(outcome.rejection)
        XCTAssertTrue(outcome.frame.events.contains(.didAdd(id(2))))
        XCTAssertTrue(outcome.frame.events.contains(.didAdd(id(3))))
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        // P-B-7: w pierwszej klatce obie części stoją w regionie, poza bryłą i w różnych miejscach.
        let wall = try RigidBodyDescriptor(id: id(100), shape: try rectangle([3, -50], [60, 50]), position: .zero,
            motionRole: .static, physicsMaterialID: rigidMaterial, renderMaterialID: style)
        let first = try XCTUnwrap(outcome.frame.objects[id(2)]).position
        let second = try XCTUnwrap(outcome.frame.objects[id(3)]).position
        for part in [first, second] {
            XCTAssertTrue(try configuration().simulationRegion.contains(part))
            XCTAssertFalse(PlacementGeometry.contains(
                PlacementGeometry.shape(of: wall, at: RuntimeObject(.rigidBody(wall))), part), "poza bryłą")
        }
        XCTAssertGreaterThan(simd_distance(first, second), 1e-3, "części w różnych miejscach")
    }

    // P-B-8
    func testSplitWithoutAnyValidCandidateIsRejectedWithTheCentroidCause() async throws {
        let world = try await makeWorld { $0.add(try self.bubble(1, at: [0, 0], radius: 10)) }
        let outcome = await run(world, splitTransaction(
            after: WorldTransaction().add(try body(100, try rectangle([-50, -50], [50, 50])))))
        assertRejected(outcome, at: 1, .invalidPlacement(id(2), .insideRigidBody))
        XCTAssertNotNil(outcome.frame.objects[id(1)], "źródło zostaje")
        XCTAssertNil(outcome.frame.objects[id(2)])
        XCTAssertNil(outcome.frame.objects[id(3)])
        try await assertNextStepAccepted(world)
    }

    func testSplitRejectionReportsTheCentroidCauseNotTheLastCandidateCause() async throws {
        // Centroid pierwszej części (-101,24; 0) leży poza regionem, a wszyscy kandydaci w regionie, w tym ostatni punkt
        // spirali, są w bryle: przyczyna z centroidu to outsideRegion, z ostatniego kandydata insideRigidBody.
        let world = try await makeWorld { $0.add(try self.bubble(1, at: [-97, 0], radius: 10)) }
        let outcome = await run(world, splitTransaction(
            after: WorldTransaction().add(try body(100, try rectangle([-100, -100], [100, 100])))))
        assertRejected(outcome, at: 1, .invalidPlacement(id(2), .outsideRegion))
        XCTAssertNotNil(outcome.frame.objects[id(1)], "źródło zostaje")
        try await assertNextStepAccepted(world)
    }
}

/// Krok bez zmian stanu, z tolerancją pozycji podawaną stagerowi.
@MainActor
private final class PositionToleranceStepper: CompleteStepper {
    let positionTolerance: Float
    init(positionTolerance: Float) { self.positionTolerance = positionTolerance }
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        CompletedRuntimeStep(state: batch.state)
    }
    /// Domyślna tolerancja z extension `CompleteStepper`, dla steppera, który jej nie podaje.
    static var protocolDefault: Float { DefaultToleranceStepper().positionTolerance }
}

@MainActor
private final class DefaultToleranceStepper: CompleteStepper {
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        CompletedRuntimeStep(state: batch.state)
    }
}
