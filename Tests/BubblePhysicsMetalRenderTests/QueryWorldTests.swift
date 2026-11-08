import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-29, P-B-30, P-B-34 (G8-AC1, G8-AC3): zapytania synchroniczne odpowiadają z opublikowanego stanu świata GPU
/// i nie czytają konturów na CPU.
@MainActor
final class QueryWorldTests: XCTestCase {
    private typealias B = SceneBuilders

    /// Bańka 1 leci w prawo od (100,100); statyczne: kwadrat 2 w (300,100), koło 3 w (400,100), kapsuła 4 w (500,100).
    private func makeScene(circleFilter: CollisionFilter = .default) async throws -> (BubbleWorld, WorldFrame) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: [100, 100], radius: 10, velocity: [60, 0]))
            .add(B.box(2, at: [300, 100], half: [15, 15]))
            .add(B.circle(3, at: [400, 100], radius: 12, role: .static, filter: circleFilter))
            .add(B.capsule(4, at: [500, 100], halfLength: 20, radius: 8, role: .static)))
        let result = await B.advance(world, steps: 30)
        return (world, result.frame)
    }

    func testPointRectangleAndCircleQueriesAnswerFromPublishedState() async throws {
        let (world, frame) = try await makeScene()
        let bubble = try XCTUnwrap(frame.objects[ObjectID(rawValue: 1)])
        XCTAssertGreaterThan(simd_length(bubble.position - [100, 100]), 11, "bańka odeszła od punktu startu")
        XCTAssertEqual(world.objects(at: bubble.position), [ObjectID(rawValue: 1)])
        XCTAssertEqual(world.objects(at: [100, 100]), [], "stare miejsce bańki jest puste")
        XCTAssertEqual(world.objects(at: [310, 110]), [ObjectID(rawValue: 2)])
        XCTAssertEqual(world.objects(at: [316, 100]), [])
        XCTAssertEqual(world.objects(at: [408, 108]), [ObjectID(rawValue: 3)], "koło: odległość 11,3 < 12")
        XCTAssertEqual(world.objects(at: [409, 109]), [], "koło: odległość 12,7 w AABB, poza kołem")
        XCTAssertEqual(world.objects(at: [525, 100]), [ObjectID(rawValue: 4)])
        XCTAssertEqual(world.objects(at: [530, 100]), [])
        let all = try WorldRectangle(min: [0, 0], max: [600, 300])
        XCTAssertEqual(world.objects(in: all), (1...4).map { ObjectID(rawValue: $0) })
        XCTAssertEqual(world.objects(in: try WorldRectangle(min: [280, 80], max: [320, 120])), [ObjectID(rawValue: 2)])
        XCTAssertEqual(world.objects(inCircle: [450, 100], radius: 40), [ObjectID(rawValue: 3), ObjectID(rawValue: 4)])
        XCTAssertEqual(world.objects(inCircle: [450, 100], radius: 0.1), [], "pusty środek między kołem a kapsułą")
    }

    // P-B-29: kształt L o środku ciężkości daleko od początku lokalnego. Synchroniczne zapytanie (QueryIndex) i dokładny
    // hit-test na GPU muszą się zgadzać co do pozycji bryły, więc rozbieżność konwencji pozy by tu wyszła.
    func testAsymmetricPolygonAnswersTheSameInQueriesAndInHitTest() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let l = try RigidBodyDescriptor(id: ObjectID(rawValue: 5),
            vertices: [[0, 0], [10, 0], [10, 2], [2, 2], [2, 10], [0, 10]], position: [300, 100], rotation: .pi / 2,
            motionRole: .static, physicsMaterialID: B.polygonMaterial, renderStyleID: B.style)
        world.submit(try B.baseTransaction().add(.rigidBody(l)))
        _ = await B.advance(world, steps: 2)
        // Obrót o π/2: lokalny (x, y) trafia do (300 − y, 100 + x).
        let points: [(WorldPoint, ObjectID?)] = [
            ([299, 108], ObjectID(rawValue: 5)), ([292, 101], ObjectID(rawValue: 5)),
            ([292, 108], nil), ([296.8, 103.2], nil), ([320, 100], nil)]
        let tasks = points.map { point, _ in Task { @MainActor in await world.hitTest(point) } }
        for _ in 0..<1000 where world.pendingHitTestCount != points.count { await Task.yield() }
        _ = await world.advance(by: B.step)
        for ((point, expected), task) in zip(points, tasks) {
            XCTAssertEqual(world.objects(at: point), expected.map { [$0] } ?? [], "objects(at: \(point))")
            let hit = await task.value
            XCTAssertEqual(hit, expected, "hitTest(\(point))")
        }
    }

    func testRaycastFindsFirstHitAndFilterNarrowsIt() async throws {
        let (world, _) = try await makeScene(circleFilter: CollisionFilter(category: 2, mask: .max))
        let hit = try XCTUnwrap(world.raycast(from: [350, 100], to: [600, 100]))
        XCTAssertEqual(hit.objectID, ObjectID(rawValue: 3))
        XCTAssertEqual(hit.point.x, 388, accuracy: 1e-3)
        XCTAssertEqual(hit.normal.x, -1, accuracy: 1e-3)
        XCTAssertEqual(hit.fraction, (388 - 350) / 250, accuracy: 1e-4)
        // Koło w kategorii 2 jest poza maską zapytania, więc pierwsza jest kapsuła.
        let filtered = try XCTUnwrap(world.raycast(from: [350, 100], to: [600, 100],
            filter: CollisionFilter(category: 1, mask: 1)))
        XCTAssertEqual(filtered.objectID, ObjectID(rawValue: 4))
        XCTAssertEqual(filtered.point.x, 472, accuracy: 1e-3)
        XCTAssertEqual(world.objects(at: [400, 100], filter: CollisionFilter(category: 1, mask: 1)), [])
        XCTAssertEqual(world.objects(at: [400, 100]), [ObjectID(rawValue: 3)])
    }

    func testRemovedObjectLeavesQueriesWithTheStepThatPublishesTheRemoval() async throws {
        let (world, _) = try await makeScene()
        world.submit(WorldTransaction().remove(ObjectID(rawValue: 2)))
        XCTAssertEqual(world.objects(at: [300, 100]), [ObjectID(rawValue: 2)], "zapytanie czyta opublikowany stan")
        _ = await world.advance(by: B.step)
        XCTAssertEqual(world.objects(at: [300, 100]), [])
    }

    // P-B-34: żadne zapytanie nie czyta konturów; indeks powstaje najwyżej raz na publikację, przy pierwszym zapytaniu.
    func testQueriesReadNoContoursAndIndexIsBuiltOncePerPublication() async throws {
        let (world, _) = try await makeScene()
        XCTAssertEqual(world.queryIndexBuildCount, 0, "publikacja bez zapytania nie buduje indeksu")
        _ = world.objects(at: [300, 100])
        _ = world.objects(in: try WorldRectangle(min: [0, 0], max: [10, 10]))
        _ = world.objects(inCircle: [450, 100], radius: 40)
        _ = world.raycast(from: [0, 100], to: [600, 100])
        XCTAssertEqual(world.queryIndexBuildCount, 1)
        _ = await world.advance(by: B.step)
        XCTAssertEqual(world.queryIndexBuildCount, 1, "nowa publikacja sama nie buduje indeksu")
        _ = world.objects(at: [300, 100])
        _ = world.objects(at: [301, 100])
        XCTAssertEqual(world.queryIndexBuildCount, 2)
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }

    func testWorldWithoutAnyStepAnswersEmpty() throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        XCTAssertEqual(world.objects(at: [10, 10]), [])
        XCTAssertNil(world.raycast(from: [0, 0], to: [100, 100]))
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }
}
