import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-22 i P-B-69 (G11-AC1, G7-AC2, G2-AC1): kontakt i rozdzielenie każdej pary kształtów (bańka, wielokąt, koło,
/// kapsuła), także statycznego koła i kapsuły wobec bańki; start z rdzeniem we wnętrzu wielokąta i z kołami o tym samym środku.
@MainActor
final class RigidShapeContactTests: XCTestCase {
    private typealias B = SceneBuilders

    private enum Shape: CaseIterable, CustomStringConvertible {
        case bubble, box, circle, capsule
        var description: String {
            switch self { case .bubble: return "bańka"; case .box: return "wielokąt"; case .circle: return "koło"; case .capsule: return "kapsuła" }
        }
        /// Połowa rozpiętości wzdłuż osi X (kapsuła leży poziomo).
        var halfWidth: Float {
            switch self { case .bubble: return 8; case .box: return 10; case .circle: return 9; case .capsule: return 14 }
        }
        func make(_ id: UInt64, at center: WorldPoint, role: MotionRole, velocity: WorldPoint = .zero,
                  interest: EventInterest = [], taller: Bool = false) throws -> WorldObject {
            switch self {
            case .bubble: return try B.bubble(id, at: center, radius: 8, velocity: velocity, interest: interest, role: role)
            case .box: return try B.box(id, at: center, half: [10, taller ? 9 : 7], role: role, velocity: velocity, interest: interest)
            case .circle: return try B.circle(id, at: center, radius: 9, role: role, velocity: velocity, interest: interest)
            case .capsule: return try B.capsule(id, at: center, halfLength: 8, radius: 6, role: role, velocity: velocity, interest: interest)
            }
        }
    }

    private func world(region: WorldRectangle? = nil) throws -> BubbleWorld {
        try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), region: region)
    }

    private func state(_ frame: WorldFrame, _ id: UInt64) throws -> ObjectState {
        try XCTUnwrap(frame.objects[ObjectID(rawValue: id)], "brak obiektu \(id)")
    }

    private func assertFinite(_ frame: WorldFrame, file: StaticString = #filePath, line: UInt = #line) {
        for (id, object) in frame.objects {
            XCTAssertTrue(object.position.x.isFinite && object.position.y.isFinite && object.velocity.x.isFinite
                && object.velocity.y.isFinite && object.rotation.isFinite, "obiekt \(id.rawValue) ma wartości nieskończone",
                file: file, line: line)
        }
    }

    // Bez zdarzeń i bez błędu klatki: świat nie przeszedł w stan „zawiódł”.
    private func assertHealthy(_ world: BubbleWorld, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "\(context): klatka nie może się nie udać", file: file, line: line)
    }
    private func healthy(_ world: BubbleWorld, _ context: String, file: StaticString = #filePath, line: UInt = #line) {
        assertHealthy(world, context, file: file, line: line)
    }

    // P-B-22: zderzenie czołowe w poziomie. Jeden rodzaj ciała wpada na statyczne ciało drugiego rodzaju (wszystkie
    // 16 par, w tym statyczne koło i kapsuła wobec bańki). Zatrzymuje się przy powierzchni, a `contactBegan` ma impuls > 0.
    func testEveryShapePairCollidesAgainstStaticBody() async throws {
        for mover in Shape.allCases {
            for target in Shape.allCases {
                let context = "\(mover) → statyczny \(target)"
                let world = try world()
                let targetX: Float = 150
                // Szczelina nie jest całkowita (przy 1 jednostce na krok styk wypadłby dokładnie na krawędzi), uderzenie jest
                // centralne (bez obrotu), a statyczny wielokąt wyższy, żeby krawędzie obu nie leżały na jednej prostej.
                let startX = targetX - target.halfWidth - mover.halfWidth - 12.4
                world.submit(try B.baseTransaction()
                    .add(target.make(2, at: [targetX, 100], role: .static, taller: true))
                    .add(mover.make(1, at: [startX, 100], role: .dynamic, velocity: [60, 0], interest: .contact)))
                let result = await B.advance(world, steps: 90)
                assertHealthy(world, context)
                assertFinite(result.frame)
                let began = B.began(result.events).filter { B.isPair($0.a, $0.b, 1, 2) }
                XCTAssertGreaterThanOrEqual(began.count, 1, "\(context): brak contactBegan")
                if let event = began.first {
                    XCTAssertGreaterThan(event.impulse, 0, "\(context): impuls kontaktu")
                    XCTAssertEqual(simd_length(event.normal), 1, accuracy: 1e-3, context)
                    let towardTarget: Float = event.a.rawValue == 1 ? 1 : -1
                    XCTAssertGreaterThan(event.normal.x * towardTarget, 0.7, "\(context): normalna od pierwszego do drugiego")
                }
                let moved = try state(result.frame, 1)
                let expected = targetX - target.halfWidth - mover.halfWidth
                // Dwie bańki są miękkie (kontakt XPBD z deformacją), więc zanurzają się głębiej niż kontakty brył.
                let softPair = mover == .bubble && target == .bubble
                XCTAssertEqual(moved.position.x, expected, accuracy: softPair ? 5.0 : 2.0, "\(context): stoi przy powierzchni")
                XCTAssertEqual(try state(result.frame, 2).position, [targetX, 100], "\(context): statyczne ciało stoi")
            }
        }
    }

    // P-B-22: rozdzielenie. Ciało dynamiczne wpada w spoczywające ciało dynamiczne drugiego rodzaju: popycha je i nie
    // zostaje w nim zanurzone (10 par nieuporządkowanych).
    func testEveryShapePairSeparatesWhenDynamic() async throws {
        let all = Shape.allCases
        for (i, mover) in all.enumerated() {
            for target in all[i...] {
                let context = "\(mover) → dynamiczny \(target)"
                let world = try world()
                let targetX: Float = 150
                let startX = targetX - target.halfWidth - mover.halfWidth - 12
                world.submit(try B.baseTransaction()
                    .add(target.make(2, at: [targetX, 100], role: .dynamic))
                    .add(mover.make(1, at: [startX, 100], role: .dynamic, velocity: [60, 0])))
                let result = await B.advance(world, steps: 60)
                assertHealthy(world, context)
                assertFinite(result.frame)
                let pushed = try state(result.frame, 2), moved = try state(result.frame, 1)
                XCTAssertGreaterThan(pushed.velocity.x, 3, "\(context): trafiony ma dostać pęd")
                XCTAssertGreaterThanOrEqual(pushed.position.x - moved.position.x, mover.halfWidth + target.halfWidth - 2.0,
                    "\(context): ciała nie mogą się przenikać")
            }
        }
    }

    // P-B-22 / G2-AC1: stan obiektu podaje rodzaj koła i kapsuły oraz AABB (także dla kapsuły obróconej).
    func testObjectStateReportsCircleAndCapsuleKindsWithBounds() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.circle(1, at: [100, 100], radius: 7, role: .static))
            .add(B.capsule(2, at: [200, 100], halfLength: 20, radius: 5, rotation: .pi / 2, role: .static)))
        let result = await B.advance(world, steps: 2)
        assertHealthy(world, "stan koła i kapsuły")
        let circle = try state(result.frame, 1), capsule = try state(result.frame, 2)
        XCTAssertEqual(circle.kind, .circle(radius: 7))
        XCTAssertEqual(circle.bounds.min.x, 93, accuracy: 1e-3)
        XCTAssertEqual(circle.bounds.max.y, 107, accuracy: 1e-3)
        XCTAssertEqual(capsule.kind, .capsule(halfLength: 20, radius: 5))
        XCTAssertEqual(capsule.bounds.max.x - capsule.bounds.min.x, 10, accuracy: 1e-2)
        XCTAssertEqual(capsule.bounds.max.y - capsule.bounds.min.y, 50, accuracy: 1e-2)
    }

    // P-B-22: dynamiczne koło i kapsuła nie spadają przez statyczną podłogę (przemiatanie rdzenia) i leżą na niej.
    func testDynamicCircleAndCapsuleRestOnStaticFloorUnderGravity() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), gravity: [0, -400])
        world.submit(try B.baseTransaction()
            .add(B.box(100, at: [300, 5], half: [300, 5]))
            .add(B.circle(1, at: [100, 60], radius: 9))
            .add(B.capsule(2, at: [200, 60], halfLength: 12, radius: 6, rotation: 0.3)))
        let result = await B.advance(world, steps: 180)
        assertHealthy(world, "podłoga")
        assertFinite(result.frame)
        XCTAssertEqual(try state(result.frame, 1).position.y, 10 + 9, accuracy: 1.0)
        XCTAssertGreaterThan(try state(result.frame, 2).bounds.min.y, 9.0)
        XCTAssertLessThan(try state(result.frame, 2).bounds.min.y, 12.0)
    }

    // P-B-69: koło z rdzeniem we wnętrzu wielokąta i kapsuła z rdzeniem we wnętrzu wielokąta wychodzą na zewnątrz.
    func testCircleAndCapsuleStartingInsidePolygonSeparate() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.box(10, at: [100, 100], half: [30, 30], role: .static))
            .add(B.circle(1, at: [104, 100], radius: 5))
            .add(B.box(11, at: [300, 100], half: [30, 30], role: .static))
            .add(B.capsule(2, at: [300, 96], halfLength: 10, radius: 4)))
        let result = await B.advance(world, steps: 90)
        assertHealthy(world, "rdzeń we wnętrzu")
        assertFinite(result.frame)
        let circle = try state(result.frame, 1), capsule = try state(result.frame, 2)
        XCTAssertGreaterThanOrEqual(max(abs(circle.position.x - 100), abs(circle.position.y - 100)), 30 + 5 - 1.0,
            "koło poza wielokątem")
        XCTAssertGreaterThanOrEqual(max(abs(capsule.bounds.min.x - 300), abs(capsule.bounds.max.x - 300),
            abs(capsule.bounds.min.y - 100), abs(capsule.bounds.max.y - 100)), 30,
            "kapsuła nie może zostać całkiem we wnętrzu")
        let inside = (capsule.bounds.min.x > 270 && capsule.bounds.max.x < 330 && capsule.bounds.min.y > 70 && capsule.bounds.max.y < 130)
        XCTAssertFalse(inside, "kapsuła wypchnięta z wielokąta")
    }

    // G11-AC1: obrys koła i kapsuły do rysowania ma właściwą liczbę wierzchołków i zasięg (pierścień lokalny z rdzenia i promienia;
    // pozę w świecie nakłada shader, co sprawdzają testy obrazu).
    func testRenderStateRingsOfCircleAndCapsuleHaveExpectedVertexCountAndExtent() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.circle(1, at: [100, 100], radius: 9, role: .static))
            .add(B.capsule(2, at: [300, 150], halfLength: 20, radius: 5, role: .static)))
        _ = await B.advance(world, steps: 1)
        let shapes = try XCTUnwrap(world.renderState).layers.flatMap(\.shapes)
        XCTAssertEqual(shapes.count, 2)
        let circle = shapes[0], capsule = shapes[1]
        XCTAssertEqual(circle.localVertices.count, 48)
        XCTAssertEqual(circle.localVertices.map { simd_length($0) }.min() ?? 0, 9, accuracy: 1e-3, "wszystkie wierzchołki na okręgu")
        XCTAssertEqual(circle.localVertices.map { simd_length($0) }.max() ?? 0, 9, accuracy: 1e-3)
        XCTAssertEqual(capsule.localVertices.count, 50)
        XCTAssertEqual(capsule.localVertices.map { $0.x }.max() ?? 0, 25, accuracy: 1e-3)
        XCTAssertEqual(capsule.localVertices.map { $0.x }.min() ?? 0, -25, accuracy: 1e-3)
        XCTAssertEqual(capsule.localVertices.map { $0.y }.max() ?? 0, 5, accuracy: 1e-3)
        XCTAssertEqual(capsule.localVertices.map { $0.y }.min() ?? 0, -5, accuracy: 1e-3)
    }

    // P-B-69: kapsuła poprzeczna do cienkiej ściany, poza jej środkiem, z oboma końcami rdzenia na zewnątrz wielokąta.
    // Rdzeń przecina obrys, więc rozdzielenie ma iść wzdłuż normalnej ściany (najmniejsze wnikanie), a nie stycznie.
    func testCapsuleAcrossThinWallOffCentreSeparatesAlongWallNormal() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.box(10, at: [300, 100], half: [100, 2], role: .static))
            .add(B.capsule(1, at: [330, 100.5], halfLength: 10, radius: 3, rotation: .pi / 2)))
        let result = await B.advance(world, steps: 60)
        assertHealthy(world, "kapsuła w poprzek ściany")
        assertFinite(result.frame)
        let capsule = try state(result.frame, 1)
        XCTAssertEqual(capsule.position.x, 330, accuracy: 3, "bez ruchu stycznego wzdłuż ściany")
        let clearsTop = capsule.bounds.min.y >= 102 - 0.1, clearsBottom = capsule.bounds.max.y <= 98 + 0.1
        XCTAssertTrue(clearsTop || clearsBottom, "kapsuła rozdzielona od ściany wzdłuż jej normalnej: \(capsule.bounds)")
    }

    // P-B-69: dwa koła o tym samym środku rozdzielają się deterministycznie (stała oś, kierunek od mniejszego ObjectID).
    func testTwoCirclesWithTheSameCenterSeparate() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.circle(1, at: [150, 100], radius: 8))
            .add(B.circle(2, at: [150, 100], radius: 8)))
        let result = await B.advance(world, steps: 60)
        assertHealthy(world, "koła współśrodkowe")
        assertFinite(result.frame)
        let first = try state(result.frame, 1), second = try state(result.frame, 2)
        XCTAssertGreaterThanOrEqual(simd_distance(first.position, second.position), 16 - 1.0)
        XCTAssertLessThan(first.position.x, second.position.x, "od mniejszego ObjectID wzdłuż stałej osi (1, 0)")
    }

    // P-B-69: ściśnięty stos kół i kapsuł w ciasnym zbiorniku pod grawitacją: skończone wartości, brak błędu klatki.
    func testSqueezedStackStaysFiniteAndHealthy() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
                                    region: WorldRectangle(min: [-50, -50], max: [300, 300]), gravity: [0, -400])
        var transaction = try B.baseTransaction()
            .add(B.box(100, at: [100, 5], half: [100, 5]))
            .add(B.box(101, at: [-5, 100], half: [5, 100]))
            .add(B.box(102, at: [205, 100], half: [5, 100]))
        for index in 0..<24 {
            let x = 30 + Float(index % 6) * 22, y = 40 + Float(index / 6) * 14
            transaction = index % 3 == 0
                ? transaction.add(try B.capsule(UInt64(index + 1), at: [x, y], halfLength: 6, radius: 5))
                : transaction.add(try B.circle(UInt64(index + 1), at: [x, y], radius: 7))
        }
        world.submit(transaction)
        let result = await B.advance(world, steps: 240)
        assertHealthy(world, "ściśnięty stos")
        assertFinite(result.frame)
        for index in 1...24 {
            let object = try state(result.frame, UInt64(index))
            XCTAssertGreaterThan(object.position.y, 0, "obiekt \(index) nie wypadł pod podłogę")
            XCTAssertGreaterThan(object.position.x, 0)
            XCTAssertLessThan(object.position.x, 200)
        }
    }

    // Czujnik widzi koło i kapsułę przez rdzeń z promieniem: okrągły i wielokątny zasięg, bliski i daleki obiekt.
    func testSensorsDetectCircleAndCapsuleByCoreAndRadius() async throws {
        let world = try world()
        let round = try SensorDescriptor(id: ObjectID(rawValue: 90), position: [100, 100], geometry: RangeGeometry.circle(radius: 10), eventInterest: .enteredSensor)
        let square = try SensorDescriptor(id: ObjectID(rawValue: 91), position: [300, 100],
            geometry: RangeGeometry.polygon(vertices: [[-10, -10], [10, -10], [10, 10], [-10, 10]]), eventInterest: .enteredSensor)
        world.submit(try B.baseTransaction()
            .add(.sensor(round)).add(.sensor(square))
            // Odległość rdzenia od środka okrągłego czujnika 12 ≤ 10 + 5; kapsuła daleko: 17 > 10 + 3.
            .add(B.circle(1, at: [112, 100], radius: 5, role: .static))
            .add(B.capsule(2, at: [125, 100], halfLength: 8, radius: 3, role: .static))
            // Wielokątny czujnik: kapsuła wchodzi końcem rdzenia (odległość rdzenia do krawędzi 2 ≤ 3), koło nie sięga (odległość 8 > 5).
            .add(B.capsule(3, at: [318, 100], halfLength: 6, radius: 3, role: .static))
            .add(B.circle(4, at: [300, 118], radius: 5, role: .static)))
        let result = await B.advance(world, steps: 3)
        healthy(world, "czujniki")
        let entered = result.events.compactMap { event -> (UInt64, UInt64)? in
            if case .enteredSensor(let sensor, let object) = event { return (sensor.rawValue, object.rawValue) }
            return nil
        }
        XCTAssertTrue(entered.contains { $0 == (90, 1) }, "koło w okrągłym zasięgu")
        XCTAssertFalse(entered.contains { $0 == (90, 2) }, "kapsuła poza zasięgiem")
        XCTAssertTrue(entered.contains { $0 == (91, 3) }, "kapsuła w wielokątnym zasięgu")
        XCTAssertFalse(entered.contains { $0 == (91, 4) }, "koło poza wielokątnym zasięgiem")
    }
}
