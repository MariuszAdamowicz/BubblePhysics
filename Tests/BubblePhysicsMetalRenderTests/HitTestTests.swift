import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// P-B-31, P-B-32, P-B-33, P-B-34 (G8-AC2, G8-AC3): asynchroniczny hit-test dokładnych konturów i brył na GPU,
/// liczony na stanie następnego ukończonego kroku.
@MainActor
final class HitTestTests: XCTestCase {
    private typealias B = SceneBuilders
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func makeWorld(region: WorldRectangle? = nil) throws -> BubbleWorld {
        try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), region: region)
    }

    /// Czeka, aż świat zarejestruje `count` oczekujących zapytań (zadania `hitTest` startują asynchronicznie).
    private func waitForPending(_ world: BubbleWorld, _ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 where world.pendingHitTestCount != count { await Task.yield() }
        XCTAssertEqual(world.pendingHitTestCount, count, file: file, line: line)
    }

    /// Rozstrzyga zapytania jednym krokiem i zwraca wyniki w kolejności punktów.
    private func hitTests(_ world: BubbleWorld, _ points: [WorldPoint], before: () -> Void = {}) async -> [ObjectID?] {
        let tasks = points.map { point in Task { @MainActor in await world.hitTest(point) } }
        await waitForPending(world, points.count)
        before()
        _ = await world.advance(by: B.step)
        var results: [ObjectID?] = []
        for task in tasks { results.append(await task.value) }
        return results
    }

    /// Dodaje zasoby i obiekty, po czym wykonuje kilka kroków bez zapytań.
    private func settle(_ world: BubbleWorld, _ setup: WorldTransaction, steps: Int = 2) async throws {
        world.submit(try B.baseTransaction())
        world.submit(setup)
        _ = await B.advance(world, steps: steps)
    }

    // P-B-31: wnętrze, krawędź i puste miejsce bańki; odpowiedź dla każdego punktu osobno.
    func testBubbleInsideEdgeAndEmptySpaceEachAnswerTheirOwnPoint() async throws {
        let world = try makeWorld()
        try await settle(world, WorldTransaction().add(B.bubble(7, at: [100, 100], radius: 20)))
        let results = await hitTests(world, [[100, 100], [119, 100], [121, 100], [100, 80.5], [200, 200]])
        XCTAssertEqual(results, [id(7), id(7), nil, id(7), nil])
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
        XCTAssertEqual(world.pendingHitTestCount, 0)
    }

    // P-B-31: wgłębienie deformacji. Deformowalna bańka dociśnięta do ściany ma spłaszczony kontur, więc punkt z jej koła
    // nominalnego, który leży już poza konturem, nie należy do bańki (id 20, wygrałaby jako największy `ObjectID`).
    func testDeformationRecessIsOutsideTheBubbleContour() async throws {
        let region = try WorldRectangle(min: [-10, -10], max: [10, 10])
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), region: region)
        // Materiał bez deformowalności daje bańkę sztywną, bez wgłębienia; tu bańka musi być deformowalna.
        world.submit(try B.baseTransaction()
            .updatePhysicsMaterial(B.bubbleMaterial, material: PhysicsMaterial(kind: .bubble, deformability: 1))
            .add(B.box(10, at: [1, 0], half: [1, 10]))
            .add(B.bubble(20, at: [-0.6, 0], radius: 1)))
        let frame = await world.advance(by: B.step)
        // Warunek wstępny: punkt wgłębienia leży w kole nominalnym (promień 1), a poza konturem spłaszczonej bańki.
        // Efektywny promień jest najmniejszą odległością konturu, więc koło o tym promieniu leży w całości w konturze
        // i nie może zawierać wgłębienia; punkt leży poza nim, a `objects(at:)` (koło efektywne) też go nie obejmuje.
        let bubble = try XCTUnwrap(frame.objects[id(20)])
        guard case .bubble(let effectiveRadius) = bubble.kind else { return XCTFail("obiekt 20 nie jest bańką") }
        let recess = WorldPoint(-0.1, 0)
        let offset = recess - bubble.position
        let distance = (offset * offset).sum().squareRoot()
        XCTAssertLessThan(distance, 1, "punkt wgłębienia leży w kole nominalnym (promień 1)")
        XCTAssertGreaterThan(distance, effectiveRadius, "punkt wgłębienia leży poza kołem efektywnego promienia")
        XCTAssertLessThan(bubble.bounds.max.x, recess.x, "kontur spłaszczonej bańki nie sięga punktu wgłębienia")
        let results = await hitTests(world, [recess, [-0.5, 0], [0.05, 0], [-3, 0]])
        XCTAssertEqual(results, [nil, id(20), id(10), nil])
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }

    // P-B-31: wielokąt (także obrócony), koło i kapsuła są sprawdzane dokładnie.
    func testRigidShapesAreHitExactly() async throws {
        let world = try makeWorld()
        let diamond = try RigidBodyDescriptor(id: id(2), shape: .polygon(PolygonGeometry(vertices:
            [[-5, -5], [5, -5], [5, 5], [-5, 5]])), position: [300, 100], rotation: .pi / 4, motionRole: .static,
            physicsMaterialID: B.polygonMaterial, renderMaterialID: B.style)
        try await settle(world, WorldTransaction()
            .add(B.box(1, at: [100, 100], half: [10, 10]))
            .add(.rigidBody(diamond))
            .add(B.circle(3, at: [400, 100], radius: 12, role: .static))
            .add(B.capsule(4, at: [500, 100], halfLength: 20, radius: 8, role: .static)))
        let results = await hitTests(world, [
            [108, 108], [112, 100], // kwadrat: wnętrze, poza
            [306, 100], [304.5, 104.5], // romb: wnętrze, w AABB poza kształtem
            [408, 108], [409, 109], // koło: wewnątrz, w AABB poza kołem
            [525, 100], [530, 100], [500, 107], [500, 109]]) // kapsuła
        XCTAssertEqual(results, [id(1), nil, id(2), nil, id(3), nil, id(4), nil, id(4), nil])
    }

    // P-B-32: nakładanie w tej samej warstwie; wygrywa największy ObjectID, niezależnie od kolejności dodania i rodzaju.
    func testLargestObjectIDWinsInOneLayerRegardlessOfInsertionOrderOrKind() async throws {
        let world = try makeWorld()
        try await settle(world, WorldTransaction()
            .add(B.bubble(11, at: [100, 100], radius: 10, role: .static))
            .add(B.bubble(9, at: [100, 100], radius: 10, role: .static))
            .add(B.bubble(5, at: [300, 100], radius: 10, role: .static))
            .add(B.box(8, at: [300, 100], half: [6, 6]))
            .add(B.bubble(3, at: [500, 100], radius: 10, role: .static))
            .add(B.box(8_000, at: [500, 100], half: [6, 6])))
        let results = await hitTests(world, [[100, 100], [300, 100], [500, 100]])
        XCTAssertEqual(results, [id(11), id(8), id(8_000)])
    }

    // P-B-32: obiekt usunięty przed krokiem nie bierze udziału, więc wygrywa obiekt pod nim.
    func testObjectRemovedBeforeTheStepDoesNotTakePart() async throws {
        let world = try makeWorld()
        try await settle(world, WorldTransaction()
            .add(B.bubble(11, at: [100, 100], radius: 10, role: .static))
            .add(B.bubble(9, at: [100, 100], radius: 10, role: .static)))
        let results = await hitTests(world, [[100, 100]]) { world.submit(WorldTransaction().remove(self.id(11))) }
        XCTAssertEqual(results, [id(9)])
    }

    // P-B-31: świat bez baniek i brył (krok GPU pominięty) odpowiada nil, a zapytanie się kończy.
    func testWorldWithoutBubblesAndBodiesAnswersNil() async throws {
        let world = try makeWorld()
        _ = await world.advance(by: B.step)
        var results = await hitTests(world, [[10, 10], [0, 0]])
        XCTAssertEqual(results, [nil, nil])
        world.submit(try B.baseTransaction().add(.sensor(SensorDescriptor(id: id(1), position: [50, 50],
            geometry: .circle(radius: 20)))))
        _ = await world.advance(by: B.step)
        results = await hitTests(world, [[50, 50]])
        XCTAssertEqual(results, [nil], "czujnik nie jest trafiany")
    }

    // P-B-33: w pauzie zapytanie czeka na wznowienie.
    func testHitTestInPauseWaitsForResume() async throws {
        let world = try makeWorld()
        try await settle(world, WorldTransaction().add(B.bubble(7, at: [100, 100], radius: 20, role: .static)))
        world.pause()
        var finished = false
        let task = Task { @MainActor () -> ObjectID? in
            let result = await world.hitTest([100, 100])
            finished = true
            return result
        }
        await waitForPending(world, 1)
        _ = await world.advance(by: 1)
        for _ in 0..<50 { await Task.yield() }
        XCTAssertFalse(finished)
        XCTAssertEqual(world.pendingHitTestCount, 1)
        world.resume()
        _ = await world.advance(by: B.step)
        let result = await task.value
        XCTAssertEqual(result, id(7))
        XCTAssertEqual(world.pendingHitTestCount, 0)
    }

    // P-B-33: punkt nieskończony i zadanie anulowane przed wywołaniem dają nil od razu, bez kolejki.
    func testNonFinitePointAndAlreadyCancelledTaskAnswerNilImmediately() async throws {
        let world = try makeWorld()
        let nan = await world.hitTest([.nan, 0])
        let infinite = await world.hitTest([0, .infinity])
        XCTAssertNil(nan)
        XCTAssertNil(infinite)
        let cancelled = Task { @MainActor () -> ObjectID? in
            withUnsafeCurrentTask { $0?.cancel() }
            return await world.hitTest([1, 1])
        }
        let result = await cancelled.value
        XCTAssertNil(result)
        XCTAssertEqual(world.pendingHitTestCount, 0)
    }

    // P-B-33: anulowanie zadania w trakcie oczekiwania zwraca nil od razu i usuwa żądanie; reszta zapytań działa dalej.
    func testCancellingTheTaskAnswersNilAndRemovesOnlyThatRequest() async throws {
        let world = try makeWorld()
        try await settle(world, WorldTransaction().add(B.bubble(7, at: [100, 100], radius: 20, role: .static)))
        world.pause()
        let cancelled = Task { @MainActor in await world.hitTest([100, 100]) }
        let kept = Task { @MainActor in await world.hitTest([100, 100]) }
        await waitForPending(world, 2)
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertNil(cancelledResult)
        XCTAssertEqual(world.pendingHitTestCount, 1)
        world.resume()
        _ = await world.advance(by: B.step)
        let keptResult = await kept.value
        XCTAssertEqual(keptResult, id(7))
    }

    // P-B-33: oczekujące żądanie trzyma świat przy życiu, a anulowanie zadania go zwalnia, także bez kolejnych `advance`.
    func testCancellingAbandonedWorldInPauseReleasesTheWorld() async throws {
        weak var weakWorld: BubbleWorld?
        var task: Task<ObjectID?, Never>?
        do {
            let world = try makeWorld()
            weakWorld = world
            world.pause()
            task = Task { @MainActor in await world.hitTest([1, 1]) }
            await waitForPending(world, 1)
        }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotNil(weakWorld, "oczekujące żądanie trzyma świat")
        task?.cancel()
        let result = try await XCTUnwrap(task).value
        XCTAssertNil(result)
        for _ in 0..<50 where weakWorld != nil { await Task.yield() }
        XCTAssertNil(weakWorld, "po anulowaniu nic nie trzyma świata")
    }

    // P-B-33 (rozstrzygnięcie na publikacji): zapytanie złożone w czasie kroku jest odpowiedziane najpóźniej następnym krokiem.
    func testRequestAddedDuringAStepIsAnsweredNoLaterThanTheNextStep() async throws {
        let world = try makeWorld()
        try await settle(world, WorldTransaction().add(B.bubble(7, at: [100, 100], radius: 20, role: .static)))
        let first = Task { @MainActor in await world.hitTest([100, 100]) }
        await waitForPending(world, 1)
        let stepping = Task { @MainActor in await world.advance(by: B.step) }
        let second = Task { @MainActor in await world.hitTest([100, 100]) }
        _ = await stepping.value
        let firstResult = await first.value
        XCTAssertEqual(firstResult, id(7))
        // Drugie zapytanie jest odpowiedziane najpóźniej następnym krokiem.
        _ = await world.advance(by: B.step)
        let secondResult = await second.value
        XCTAssertEqual(secondResult, id(7))
        XCTAssertEqual(world.pendingHitTestCount, 0)
    }
}
