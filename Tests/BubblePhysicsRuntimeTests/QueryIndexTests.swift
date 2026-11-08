import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest
import simd

/// P-B-29, P-B-30: zapytania punkt, prostokąt, koło i raycast na zbudowanym `RuntimeState`, bez GPU.
/// Bryły są sprawdzane dokładnie, bańka jako koło o efektywnym promieniu, a filtr zawęża wynik.
final class QueryIndexTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderStyleID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func transaction() throws -> WorldTransaction {
        try WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(rigidMaterial, material: PhysicsMaterial(kind: .rigid))
            .updateRenderStyle(style, style: RenderStyle())
    }

    private func bubble(_ value: UInt64, at position: WorldPoint, radius: Float = 5,
                        filter: CollisionFilter = .default) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, targetRadius: radius,
            physicsMaterialID: bubbleMaterial, renderStyleID: style, filter: filter))
    }

    private func rigid(_ value: UInt64, shape: RigidShape, at position: WorldPoint, rotation: Float = 0,
                       filter: CollisionFilter = .default) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), shape: shape, position: position, rotation: rotation,
            motionRole: .static, physicsMaterialID: rigidMaterial, renderStyleID: style, filter: filter))
    }

    private func box(half: Float) throws -> RigidShape {
        .polygon(try PolygonGeometry(vertices: [[-half, -half], [half, -half], [half, half], [-half, half]]))
    }

    /// Bańka 1 (0,0) r5; romb 2 (obrócony kwadrat o połowie 5, wierzchołki 7,07 od środka (30,0)); koło 3 (−30,0) r4;
    /// kapsuła 4 w (0,30) z pionową osią (półdługość 6, promień 2), czyli x ∈ [−2, 2], y ∈ [22, 38].
    private func scene(extra: [WorldObject] = [], circleFilter: CollisionFilter = .default,
                       build: (inout RuntimeState) -> Void = { _ in }) throws -> QueryIndex {
        var change = try transaction()
            .add(bubble(1, at: [0, 0]))
            .add(rigid(2, shape: box(half: 5), at: [30, 0], rotation: .pi / 4))
            .add(rigid(3, shape: .circle(radius: 4), at: [-30, 0], filter: circleFilter))
            .add(rigid(4, shape: .capsule(halfLength: 6, radius: 2), at: [0, 30], rotation: .pi / 2))
        for object in extra { change = change.add(object) }
        var state = try TransactionStager.stage(change, against: RuntimeState(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100])))).state
        build(&state)
        return QueryIndex(state: state)
    }

    // MARK: punkt

    func testPointQueryIsExactForEveryShape() throws {
        let index = try scene()
        XCTAssertEqual(index.objects(at: [3, 3]), [id(1)], "bańka: wnętrze koła")
        XCTAssertEqual(index.objects(at: [4, 4]), [], "bańka: poza kołem, w jej prostokącie")
        XCTAssertEqual(index.objects(at: [36, 0]), [id(2)], "romb: wnętrze")
        XCTAssertEqual(index.objects(at: [34.5, 4.5]), [], "romb: w AABB, poza obróconym kształtem")
        XCTAssertEqual(index.objects(at: [-27, 3]), [id(3)], "koło: wnętrze")
        XCTAssertEqual(index.objects(at: [-27, 3.4]), [], "koło: poza kołem, w AABB")
        XCTAssertEqual(index.objects(at: [0, 37]), [id(4)], "kapsuła: wnętrze półkola końca")
        XCTAssertEqual(index.objects(at: [1.9, 37.9]), [], "kapsuła: w AABB, poza zaokrągleniem")
        XCTAssertEqual(index.objects(at: [1.9, 28]), [id(4)], "kapsuła: wnętrze prostej części")
        XCTAssertEqual(index.objects(at: [0, -60]), [], "puste miejsce")
    }

    func testPointQueryUsesEffectiveRadiusOfBubble() throws {
        let index = try scene { state in state.objects[self.id(1)]?.effectiveRadius = 2 }
        XCTAssertEqual(index.objects(at: [1.5, 0]), [id(1)])
        XCTAssertEqual(index.objects(at: [3, 0]), [], "poza efektywnym promieniem, choć w docelowym")
    }

    func testPointQueryReturnsOverlappingObjectsSortedByID() throws {
        let index = try scene(extra: [bubble(9, at: [1, 0]), bubble(7, at: [-1, 0])])
        XCTAssertEqual(index.objects(at: [0, 0]), [id(1), id(7), id(9)])
    }

    // MARK: prostokąt

    func testRectangleQueryIsExactForEveryShape() throws {
        let index = try scene()
        func rect(_ a: WorldPoint, _ b: WorldPoint) throws -> WorldRectangle { try WorldRectangle(min: a, max: b) }
        XCTAssertEqual(index.objects(in: try rect([4, 4], [6, 6])), [], "bańka: róg prostokąta poza kołem")
        XCTAssertEqual(index.objects(in: try rect([3, 3], [6, 6])), [id(1)], "bańka: róg wewnątrz koła")
        XCTAssertEqual(index.objects(in: try rect([5.5, -10], [6, 10])), [], "bańka: pas obok koła")
        XCTAssertEqual(index.objects(in: try rect([-1, -1], [1, 1])), [id(1)], "prostokąt wewnątrz bańki")
        XCTAssertEqual(index.objects(in: try rect([34, 4], [36, 6])), [], "romb: prostokąt w AABB, poza rombem")
        XCTAssertEqual(index.objects(in: try rect([29, -1], [31, 1])), [id(2)], "prostokąt wewnątrz rombu, bez wierzchołków i krawędzi")
        XCTAssertEqual(index.objects(in: try rect([36, -1], [40, 1])), [id(2)], "prostokąt zahacza o wierzchołek rombu")
        XCTAssertEqual(index.objects(in: try rect([-27, 3.4], [-25, 5])), [], "koło: róg poza kołem")
        XCTAssertEqual(index.objects(in: try rect([-27, 2.5], [-25, 5])), [id(3)], "koło: róg wewnątrz")
        XCTAssertEqual(index.objects(in: try rect([1.9, 37.9], [5, 40])), [], "kapsuła: róg poza zaokrągleniem")
        XCTAssertEqual(index.objects(in: try rect([1, 37], [5, 40])), [id(4)], "kapsuła: prostokąt zahacza o koniec")
        XCTAssertEqual(index.objects(in: try rect([-100, -100], [100, 100])), [id(1), id(2), id(3), id(4)], "wszystko")
        XCTAssertEqual(index.objects(in: try rect([50, 50], [60, 60])), [], "puste miejsce")
    }

    // MARK: koło

    func testCircleQueryIsExactForEveryShape() throws {
        let index = try scene()
        XCTAssertEqual(index.objects(inCircle: [8, 0], radius: 2.9), [], "bańka: koło zapytania tuż obok")
        XCTAssertEqual(index.objects(inCircle: [8, 0], radius: 3.1), [id(1)])
        XCTAssertEqual(index.objects(inCircle: [34.5, 4.5], radius: 1), [], "romb: koło w AABB, poza rombem")
        XCTAssertEqual(index.objects(inCircle: [34.5, 4.5], radius: 2), [id(2)], "romb: odległość od krawędzi 1,37 < 2")
        XCTAssertEqual(index.objects(inCircle: [30, 0], radius: 0.5), [id(2)], "koło wewnątrz rombu")
        XCTAssertEqual(index.objects(inCircle: [-30, 9], radius: 4.9), [], "koło: odległość 9 > 4 + 4,9")
        XCTAssertEqual(index.objects(inCircle: [-30, 9], radius: 5.1), [id(3)])
        XCTAssertEqual(index.objects(inCircle: [3, 39], radius: 2), [], "kapsuła: odległość 4,24 od końca osi > 2 + 2")
        XCTAssertEqual(index.objects(inCircle: [3, 39], radius: 2.5), [id(4)])
        XCTAssertEqual(index.objects(inCircle: [5, 30], radius: 2), [], "kapsuła: odległość 5 od prostej części > 2 + 2")
        XCTAssertEqual(index.objects(inCircle: [3.9, 30], radius: 2), [id(4)])
        XCTAssertEqual(index.objects(inCircle: [0, 0], radius: 200), [id(1), id(2), id(3), id(4)])
        XCTAssertEqual(index.objects(inCircle: [0, 0], radius: -1), [], "ujemny promień nic nie wybiera")
    }

    // MARK: filtr

    func testFilterNarrowsEveryQueryAndNilReturnsEverything() throws {
        // Filtr zapytania działa jak filtr obiektu: wynik to obiekty, z którymi taki obiekt by kolidował.
        let index = try scene(extra: [bubble(8, at: [0, 0], radius: 5, filter: CollisionFilter(category: 2, mask: 0b1))])
        XCTAssertEqual(index.objects(at: [0, 0]), [id(1), id(8)], "bez filtra: wszystko")
        XCTAssertEqual(index.objects(at: [0, 0], filter: .default), [id(1), id(8)])
        let probe = CollisionFilter(category: 1, mask: 2)
        XCTAssertEqual(index.objects(at: [0, 0], filter: probe), [id(8)], "obiekt 1 nie przyjmuje kategorii 2")
        let rejected = CollisionFilter(category: 4, mask: 2)
        XCTAssertEqual(index.objects(at: [0, 0], filter: rejected), [], "obiekt 8 ma maskę 1, nie przyjmuje kategorii 4")
        let rectangle = try WorldRectangle(min: [-1, -1], max: [1, 1])
        XCTAssertEqual(index.objects(in: rectangle, filter: probe), [id(8)])
        XCTAssertEqual(index.objects(in: rectangle, filter: rejected), [])
        XCTAssertEqual(index.objects(inCircle: [0, 0], radius: 1, filter: probe), [id(8)])
        XCTAssertEqual(index.objects(inCircle: [0, 0], radius: 1, filter: rejected), [])
        XCTAssertEqual(index.raycast(from: [-20, 0], to: [20, 0], filter: probe)?.objectID, id(8))
        XCTAssertNil(index.raycast(from: [-20, 0], to: [20, 0], filter: rejected))
        XCTAssertEqual(index.raycast(from: [-20, 0], to: [20, 0])?.objectID, id(1), "remis wygrywa mniejszy ObjectID")
    }

    func testSensorsAndForceFieldsAreNotQueryable() throws {
        let sensor = try SensorDescriptor(id: id(20), position: [60, 60], geometry: .circle(radius: 5), renderStyleID: style)
        let field = try ForceFieldDescriptor(id: id(21), position: [60, 60], geometry: .circle(radius: 5),
            field: .directional(force: [1, 0]), renderStyleID: style)
        let index = try scene(extra: [.sensor(sensor), .forceField(field)])
        XCTAssertEqual(index.objects(at: [60, 60]), [])
        XCTAssertEqual(index.objects(inCircle: [60, 60], radius: 10), [])
        XCTAssertNil(index.raycast(from: [50, 60], to: [70, 60]))
    }

    // MARK: raycast

    func testRaycastReturnsFirstHitWithPointNormalAndFraction() throws {
        let index = try scene()
        // Od lewej: najpierw koło 3 (x = −34), potem bańka 1 (x = −5), potem romb 2.
        let first = try XCTUnwrap(index.raycast(from: [-50, 0], to: [50, 0]))
        XCTAssertEqual(first.objectID, id(3))
        XCTAssertEqual(first.point.x, -34, accuracy: 1e-4)
        XCTAssertEqual(first.point.y, 0, accuracy: 1e-4)
        XCTAssertEqual(first.normal.x, -1, accuracy: 1e-4)
        XCTAssertEqual(first.normal.y, 0, accuracy: 1e-4)
        XCTAssertEqual(first.fraction, 0.16, accuracy: 1e-4)
        // Od prawej: romb ma na osi wierzchołek (ukośne krawędzie), więc trafiamy poniżej, w krawędź.
        let diamond = try XCTUnwrap(index.raycast(from: [60, 2], to: [0, 2]))
        XCTAssertEqual(diamond.objectID, id(2))
        XCTAssertEqual(diamond.point.x, 35.0711, accuracy: 1e-3)
        XCTAssertEqual(diamond.normal.x, 0.7071, accuracy: 1e-3)
        XCTAssertEqual(diamond.normal.y, 0.7071, accuracy: 1e-3)
        XCTAssertEqual(diamond.fraction, (60 - 35.0711) / 60, accuracy: 1e-4)
    }

    func testRaycastHitsCapsuleSideAndCap() throws {
        let index = try scene()
        let side = try XCTUnwrap(index.raycast(from: [10, 30], to: [-10, 30]))
        XCTAssertEqual(side.objectID, id(4))
        XCTAssertEqual(side.point.x, 2, accuracy: 1e-4)
        XCTAssertEqual(side.normal.x, 1, accuracy: 1e-4)
        XCTAssertEqual(side.fraction, 0.4, accuracy: 1e-4)
        let cap = try XCTUnwrap(index.raycast(from: [0, 50], to: [0, 0]))
        XCTAssertEqual(cap.objectID, id(4), "kapsuła przed bańką")
        XCTAssertEqual(cap.point.y, 38, accuracy: 1e-4)
        XCTAssertEqual(cap.normal.y, 1, accuracy: 1e-4)
        XCTAssertEqual(cap.fraction, 0.24, accuracy: 1e-4)
    }

    func testRaycastFilterSkipsFilteredObjects() throws {
        let hidden = try scene(circleFilter: CollisionFilter(category: 2, mask: .max))
        XCTAssertEqual(hidden.raycast(from: [-50, 0], to: [50, 0])?.objectID, id(3), "bez filtra widać wszystko")
        let hit = try XCTUnwrap(hidden.raycast(from: [-50, 0], to: [50, 0], filter: CollisionFilter(category: 1, mask: 1)))
        XCTAssertEqual(hit.objectID, id(1), "koło w kategorii 2 jest poza maską zapytania")
        XCTAssertEqual(hit.point.x, -5, accuracy: 1e-4)
        XCTAssertEqual(hit.fraction, 0.45, accuracy: 1e-4)
    }

    func testRaycastMissesAndDegenerateInput() throws {
        let index = try scene()
        XCTAssertNil(index.raycast(from: [-50, 15], to: [50, 15]), "odcinek między obiektami")
        XCTAssertNil(index.raycast(from: [-50, 0], to: [-40, 0]), "odcinek kończy się przed obiektem")
        XCTAssertNil(index.raycast(from: [0, 0], to: [.nan, 0]))
        XCTAssertNil(index.raycast(from: [.infinity, 0], to: [0, 0]))
        XCTAssertNil(index.raycast(from: [0, 15], to: [0, 15]), "odcinek zerowej długości poza obiektami")
    }

    func testRaycastStartingInsideReportsFractionZero() throws {
        let index = try scene()
        let hit = try XCTUnwrap(index.raycast(from: [1, 0], to: [20, 0]))
        XCTAssertEqual(hit.objectID, id(1))
        XCTAssertEqual(hit.fraction, 0)
        XCTAssertEqual(hit.point, [1, 0])
        XCTAssertEqual(hit.normal.x, -1, accuracy: 1e-5)
        let degenerate = try XCTUnwrap(index.raycast(from: [1, 0], to: [1, 0]))
        XCTAssertEqual(degenerate.objectID, id(1))
        XCTAssertEqual(degenerate.fraction, 0)
    }

    // MARK: pusty i duży stan

    func testEmptyStateAnswersEmpty() throws {
        let index = QueryIndex(state: RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1, -1], max: [1, 1]))))
        XCTAssertEqual(index.objects(at: .zero), [])
        XCTAssertEqual(index.objects(inCircle: .zero, radius: 5), [])
        XCTAssertNil(index.raycast(from: [-1, 0], to: [1, 0]))
    }

    func testGridAnswersMatchBruteForceOnManyObjects() throws {
        var change = try transaction()
        var expected: [UInt64: (WorldPoint, Float)] = [:]
        for index in 0..<400 {
            let x = Float(index % 20) * 9 - 90, y = Float(index / 20) * 9 - 90
            change = change.add(try bubble(UInt64(index + 1), at: [x, y], radius: 3 + Float(index % 3)))
            expected[UInt64(index + 1)] = ([x, y], 3 + Float(index % 3))
        }
        // Jeden bardzo duży obiekt obejmuje wiele komórek siatki.
        change = change.add(try rigid(1000, shape: box(half: 80), at: [0, 0]))
        let state = try TransactionStager.stage(change, against: RuntimeState(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100])))).state
        let index = QueryIndex(state: state)
        for probe in [WorldPoint(0, 0), [13.5, -22.2], [-85, 40], [99, 99], [4.4, 4.4]] {
            var want = expected.filter { simd_length($0.value.0 - probe) <= $0.value.1 }.map { id($0.key) }
            if abs(probe.x) <= 80, abs(probe.y) <= 80 { want.append(id(1000)) }
            XCTAssertEqual(index.objects(at: probe), want.sorted { $0.rawValue < $1.rawValue }, "\(probe)")
        }
        let circle = index.objects(inCircle: [10, 10], radius: 20)
        let want = expected.filter { simd_length($0.value.0 - [10, 10]) <= $0.value.1 + 20 }.map { id($0.key) } + [id(1000)]
        XCTAssertEqual(circle, want.sorted { $0.rawValue < $1.rawValue })
    }
}
