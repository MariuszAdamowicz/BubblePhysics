import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-12..P-B-15 (G7-AC2, G7-AC3): zdarzenia `contactBegan` i `contactEnded` dla każdego rodzaju pary.
/// Metody P-B-12 mają prefiks `testBegan`. Sceny stoją na statycznej podłodze pod stałą grawitacją, więc styk trwa.
@MainActor
final class ContactEventTests: XCTestCase {
    private typealias B = SceneBuilders
    private let gravity: WorldPoint = [0, -400]
    private let floorID: UInt64 = 100

    private func world(capacity: Int = 1024) throws -> BubbleWorld {
        try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), gravity: gravity, eventBufferCapacity: capacity)
    }

    private func floor() throws -> WorldObject { try B.box(floorID, at: [300, 5], half: [300, 5]) }

    /// Dokładnie jeden początek pary (x, y), z poprawnym punktem, normalną i impulsem, bez końca i bez powtórzeń.
    private func assertSingleBegan(_ events: [WorldEvent], _ frame: WorldFrame, pair x: UInt64, _ y: UInt64,
                                   normalHint: WorldPoint? = nil, file: StaticString = #filePath, line: UInt = #line) throws {
        let began = B.began(events).filter { B.isPair($0.a, $0.b, x, y) }
        XCTAssertEqual(began.count, 1, "contactBegan pary \(x)-\(y) ma być dokładnie jeden", file: file, line: line)
        XCTAssertTrue(B.ended(events).filter { B.isPair($0.0, $0.1, x, y) }.isEmpty,
            "trwały styk nie daje contactEnded", file: file, line: line)
        let event = try XCTUnwrap(began.first, file: file, line: line)
        XCTAssertEqual(simd_length(event.normal), 1, accuracy: 1e-3, "normalna jest znormalizowana", file: file, line: line)
        XCTAssertGreaterThan(event.impulse, 0, file: file, line: line)
        XCTAssertTrue(event.impulse.isFinite, file: file, line: line)
        let first = try XCTUnwrap(frame.objects[event.a], file: file, line: line)
        let second = try XCTUnwrap(frame.objects[event.b], file: file, line: line)
        // Szeroka podłoga ma środek z boku od bańki, więc dla niej kierunek od pierwszego do drugiego podaje test.
        let direction = normalHint ?? simd_normalize(second.position - first.position)
        XCTAssertGreaterThan(simd_dot(event.normal, direction), 0.7, "normalna od pierwszego obiektu do drugiego", file: file, line: line)
        let low = simd_min(first.bounds.min, second.bounds.min), high = simd_max(first.bounds.max, second.bounds.max)
        XCTAssertTrue(event.point.x >= low.x - 1 && event.point.x <= high.x + 1 && event.point.y >= low.y - 1
            && event.point.y <= high.y + 1, "punkt styku leży w obwiedni pary", file: file, line: line)
    }

    func testBeganBubbleAndStaticPolygon() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.bubble(1, at: [150, 18.3], interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, floorID, normalHint: [0, -1])
    }

    func testBeganBubbleAndBubble() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.bubble(2, at: [150, 18.3]))
            .add(B.bubble(1, at: [150, 34.6], interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, 2)
        XCTAssertTrue(B.began(result.events).allSatisfy { B.isPair($0.a, $0.b, 1, 2) },
            "para bańka–podłoga bez zainteresowania nie daje zdarzeń")
    }

    func testBeganBubbleAndDynamicPolygon() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.box(2, at: [150, 15.3], half: [20, 5], role: .dynamic))
            .add(B.bubble(1, at: [150, 28.6], interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, 2)
    }

    func testBeganDynamicPolygonAndStaticPolygon() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.box(1, at: [150, 15.15], half: [15, 5], role: .dynamic, interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, floorID, normalHint: [0, -1])
    }

    func testBeganDynamicPolygonAndDynamicPolygon() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.box(2, at: [150, 15.3], half: [20, 5], role: .dynamic))
            .add(B.box(1, at: [150, 25.6], half: [10, 5], role: .dynamic, interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, 2)
    }

    func testBeganKinematicPolygonAndDynamicPolygon() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [150, 50], half: [40, 4], role: .kinematic))
            .add(B.box(1, at: [150, 59.3], half: [8, 5], role: .dynamic, interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, 2)
    }

    func testBeganKinematicPolygonAndBubble() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [150, 50], half: [40, 4], role: .kinematic))
            .add(B.bubble(1, at: [150, 62.3], interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, 2)
    }

    /// Kroki, w których pierwszy raz przyszedł `contactBegan` pary i w których para pierwszy raz się stykała po kroku.
    private func firstSteps(_ world: BubbleWorld, steps: Int, pair x: UInt64, _ y: UInt64,
                            touching: (WorldFrame) -> Bool) async -> (began: Int?, touch: Int?, impulse: Float?, speeds: [Float]) {
        var began: Int?, touch: Int?, impulse: Float?
        var speeds: [Float] = []
        _ = await B.advance(world, steps: steps) { index, frame in
            speeds.append(frame.objects[ObjectID(rawValue: x)].map { simd_length($0.velocity) } ?? 0)
            if touch == nil, touching(frame) { touch = index }
            if began == nil, let event = B.began(frame.events).first(where: { B.isPair($0.a, $0.b, x, y) }) {
                began = index; impulse = event.impulse
            }
        }
        return (began, touch, impulse, speeds)
    }

    // P-B-12: contactBegan przychodzi dokładnie w pierwszym kroku styku: nie później (zgubiony przejście) i nie wcześniej.
    func testBeganArrivesInTheFirstStepOfContactForBubbleAndStaticPolygon() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor()).add(B.bubble(1, at: [150, 40], interest: .contact)))
        let steps = await firstSteps(world, steps: 40, pair: 1, floorID) { frame in
            (frame.objects[ObjectID(rawValue: 1)]?.bounds.min.y ?? .infinity) <= 10.05
        }
        let touch = try XCTUnwrap(steps.touch, "bańka ma dotknąć podłogi")
        XCTAssertEqual(steps.began, touch, "contactBegan w pierwszym kroku styku")
    }

    func testBeganArrivesInTheFirstStepOfContactForBubbleAndBubble() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.bubble(2, at: [150, 18.3]))
            .add(B.bubble(1, at: [150, 60], interest: .contact)))
        let steps = await firstSteps(world, steps: 60, pair: 1, 2) { frame in
            guard let a = frame.objects[ObjectID(rawValue: 1)], let b = frame.objects[ObjectID(rawValue: 2)] else { return false }
            return simd_distance(a.position, b.position) <= 16.05
        }
        let touch = try XCTUnwrap(steps.touch, "bańki mają się zetknąć")
        XCTAssertEqual(steps.began, touch, "contactBegan w pierwszym kroku styku")
    }

    func testBeganArrivesInTheFirstStepOfContactForDynamicPolygonAndStaticPolygon() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.box(1, at: [150, 40], half: [15, 5], role: .dynamic, interest: .contact)))
        let steps = await firstSteps(world, steps: 40, pair: 1, floorID) { frame in
            (frame.objects[ObjectID(rawValue: 1)]?.bounds.min.y ?? .infinity) <= 10.05
        }
        let touch = try XCTUnwrap(steps.touch, "bryła ma dotknąć podłogi")
        // Sweep `nativeRigidPredict` zatrzymuje bryłę tuż nad podłogą w kroku, w którym wejście w podłogę byłoby
        // przeskoczeniem krawędzi, więc kontakt może przyjść kilka kroków przed odczytanym stykiem, ale nigdy później.
        let began = try XCTUnwrap(steps.began, "brak contactBegan")
        XCTAssertLessThanOrEqual(began, touch, "contactBegan nie później niż pierwszy krok styku")
    }

    // P-B-12: impuls to Σλ / Δt. Dla bańki spadającej na podłogę leży między 0,3 a 1,2 prędkości zbliżania:
    // bez dzielenia przez krok byłby ok. 60 razy mniejszy, a dzielony przez krok drugi raz ok. 60 razy większy.
    func testBeganImpulseIsAccumulatedMultiplierDividedByTimeStep() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor()).add(B.bubble(1, at: [150, 40], interest: .contact)))
        let steps = await firstSteps(world, steps: 40, pair: 1, floorID) { _ in false }
        let began = try XCTUnwrap(steps.began)
        let impulse = try XCTUnwrap(steps.impulse)
        let approach = steps.speeds[began - 1]
        XCTAssertGreaterThan(approach, 50, "bańka spada z widoczną prędkością")
        XCTAssertGreaterThanOrEqual(impulse, 0.3 * approach)
        XCTAssertLessThanOrEqual(impulse, 1.2 * approach)
    }

    // P-B-12: para w szczelinie w granicach separationTolerance siedzi w cache kontaktów, ale to jeszcze nie styk.
    func testNoBeganForBubblesSeparatedByGapWithinSeparationTolerance() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: [100, 100], interest: .contact))
            .add(B.bubble(2, at: [116.001, 100])))
        let result = await B.advance(world, steps: 6)
        XCTAssertTrue(B.began(result.events).isEmpty, "bańki ze szczeliną 0,001 nie mają styku")
        XCTAssertTrue(B.ended(result.events).isEmpty)
    }

    // P-B-12: punkt jest ważony wnikaniem. Bańka w wewnętrznym rogu kształtu L styka się z dwoma odcinkami jednego
    // wielokąta, więc punkt leży bliżej odcinka, w który wnika głębiej (równe wagi dałyby środek obu punktów).
    func testBeganPointIsWeightedTowardDeeperPenetrationInACorner() async throws {
        func cornerPoint(bubbleAt position: WorldPoint) async throws -> WorldPoint {
            let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let corner = WorldObject.polygon(try PolygonDescriptor(id: ObjectID(rawValue: floorID),
                vertices: [[0, 0], [100, 0], [100, 10], [10, 10], [10, 60], [0, 60]], position: [100, 100],
                mass: 1, momentOfInertia: 1000, motionRole: .static, physicsMaterialID: B.polygonMaterial,
                renderStyleID: B.style))
            world.submit(try B.baseTransaction().add(corner).add(B.bubble(1, at: position, interest: .contact)))
            let result = await B.advance(world, steps: 2)
            let began = B.began(result.events).filter { B.isPair($0.a, $0.b, 1, floorID) }
            XCTAssertEqual(began.count, 1)
            return try XCTUnwrap(began.first).point
        }
        // Wewnętrzny róg w (110, 110): podłoga L ma górę na y = 110, ściana lewą krawędź na x = 110.
        let floorDeeper = try await cornerPoint(bubbleAt: [117.5, 116])    // podłoga 2, ściana 0,5
        let wallDeeper = try await cornerPoint(bubbleAt: [116, 117.5])     // podłoga 0,5, ściana 2
        // Punkty odcinków: podłoga (x, 110), ściana (110, y); równe wagi dałyby po (113,75 / 113) i (113 / 113,75).
        XCTAssertGreaterThan(floorDeeper.x, 115, "punkt bliżej odcinka podłogi")
        XCTAssertLessThan(floorDeeper.y, 112)
        XCTAssertLessThan(wallDeeper.x, 112, "punkt bliżej odcinka ściany")
        XCTAssertGreaterThan(wallDeeper.y, 114.5)
    }

    // P-B-13: w pierwszym kroku styku para ze scalaniem dostaje contactBegan, a dopiero po nim mergeContact, w tym samym kroku.
    func testMergeContactIsPrecededByContactBeganForTheSamePair() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let group = MergeGroupSet(rawValue: 1 << 3)
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: [100, 100], interest: [.contact, .mergeContact], mergeGroups: group))
            .add(B.bubble(2, at: [115, 100], interest: [.contact, .mergeContact], mergeGroups: group)))
        var stepsWithEvents: [(index: Int, events: [WorldEvent])] = []
        _ = await B.advance(world, steps: 5) { index, frame in stepsWithEvents.append((index, frame.events)) }
        func position(_ step: [WorldEvent], _ matches: (WorldEvent) -> Bool) -> Int? { step.firstIndex(where: matches) }
        let isBegan: (WorldEvent) -> Bool = { if case .contactBegan = $0 { return true }; return false }
        let isMerge: (WorldEvent) -> Bool = { if case .mergeContact = $0 { return true }; return false }
        let beganStep = stepsWithEvents.first { position($0.events, isBegan) != nil }
        let mergeStep = stepsWithEvents.first { position($0.events, isMerge) != nil }
        let began = try XCTUnwrap(beganStep, "brak contactBegan")
        let merge = try XCTUnwrap(mergeStep, "brak mergeContact")
        XCTAssertEqual(began.index, merge.index, "contactBegan i mergeContact pary przychodzą w tym samym kroku")
        let beganPosition = try XCTUnwrap(position(began.events, isBegan)), mergePosition = try XCTUnwrap(position(merge.events, isMerge))
        XCTAssertLessThan(beganPosition, mergePosition, "contactBegan przed mergeContact")
    }

    // P-B-14: koniec kontaktu w pierwszym kroku po rozłączeniu, liczony od kroku, w którym bańka faktycznie odjechała.
    func testEndedArrivesInFirstStepAfterSeparation() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.bubble(1, at: [150, 18.3], interest: .contact)))
        _ = await B.advance(world, steps: 30)
        world.submit(WorldTransaction().applyImpulse(to: ObjectID(rawValue: 1), impulse: [0, 300]))
        var endedAt: Int?, separatedAt: Int?
        var events: [WorldEvent] = []
        _ = await B.advance(world, steps: 20) { index, frame in
            events += frame.events
            if separatedAt == nil, (frame.objects[ObjectID(rawValue: 1)]?.bounds.min.y ?? 0) > 10.05 { separatedAt = index }
            if endedAt == nil, !B.ended(frame.events).isEmpty { endedAt = index }
        }
        XCTAssertEqual(B.ended(events).filter { B.isPair($0.0, $0.1, 1, floorID) }.count, 1)
        let separated = try XCTUnwrap(separatedAt, "bańka ma odjechać od podłogi")
        XCTAssertEqual(try XCTUnwrap(endedAt, "brak contactEnded po odskoku"), separated,
            "koniec ma przyjść w pierwszym kroku po rozłączeniu")
    }

    // P-B-14: obiekt usunięty w kroku daje koniec kontaktu pozostałemu partnerowi.
    func testEndedGoesToRemainingPartnerWhenOtherObjectIsRemoved() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.bubble(1, at: [150, 18.3], interest: .contact)))
        let settled = await B.advance(world, steps: 30)
        XCTAssertEqual(B.began(settled.events).count, 1)
        world.submit(WorldTransaction().remove(ObjectID(rawValue: floorID)))
        let removal = await world.advance(by: B.step)
        let ended = B.ended(removal.events)
        XCTAssertEqual(ended.count, 1, "koniec kontaktu w kroku usunięcia")
        XCTAssertTrue(ended.allSatisfy { B.isPair($0.0, $0.1, 1, floorID) })
    }

    // P-B-14: jedyna bańka usunięta przy styku ze statyczną podłogą (z zainteresowaniem kontaktem), która zostaje sama
    // w świecie, dostaje koniec kontaktu. Gałąź bez kroku GPU w `NativeCompleteStepper` nie wypuszcza tu nic, bo każdy
    // wielokąt ma masę, więc partner nigdy nie zostaje bez kroku GPU; w tej gałęzi pary usuniętych obu obiektów
    // jedynie znikają z historii (`testContactBetweenTwoRemovedObjectsProducesNoEventAndLeavesHistory`).
    func testEndedGoesToStaticPartnerWhenTheOnlyBubbleIsRemoved() async throws {
        let world = try world()
        world.submit(try B.baseTransaction()
            .add(B.box(floorID, at: [300, 5], half: [300, 5], interest: .contact))
            .add(B.bubble(1, at: [150, 18.3])))
        let settled = await B.advance(world, steps: 30)
        XCTAssertEqual(B.began(settled.events).count, 1)
        world.submit(WorldTransaction().remove(ObjectID(rawValue: 1)))
        let removal = await world.advance(by: B.step)
        let ended = B.ended(removal.events)
        XCTAssertEqual(ended.count, 1, "koniec kontaktu w kroku usunięcia ostatniego ciała z masą")
        XCTAssertTrue(ended.allSatisfy { B.isPair($0.0, $0.1, 1, floorID) })
    }

    // P-B-14: scalenie bańki, która stykała się z trzecią, kończy ten kontakt w kroku scalenia.
    func testEndedGoesToThirdBubbleWhenItsPartnerIsMerged() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.bubble(1, at: [150, 18.3]))
            .add(B.bubble(2, at: [166.3, 18.3]))
            .add(B.bubble(3, at: [150, 34.6], interest: .contact)))
        let settled = await B.advance(world, steps: 60)
        XCTAssertEqual(B.began(settled.events).filter { B.isPair($0.a, $0.b, 3, 1) }.count, 1)
        XCTAssertTrue(B.ended(settled.events).isEmpty, "trwały styk nie daje contactEnded")
        let result = BubbleResult(id: ObjectID(rawValue: 4), physicsMaterialID: B.bubbleMaterial, renderStyleID: B.style)
        world.submit(WorldTransaction().mergeBubbles([ObjectID(rawValue: 1), ObjectID(rawValue: 2)], result: result))
        let merge = await world.advance(by: B.step)
        XCTAssertEqual(B.ended(merge.events).filter { B.isPair($0.0, $0.1, 3, 1) }.count, 1,
            "koniec kontaktu (3, 1) w kroku scalenia")
    }

    // P-B-15: mały bufor zdarzeń i wiele styków; przepełnienie jest raportowane, a koniec nigdy nie bez początku.
    func testEventOverflowIsReportedAndNoEndComesWithoutBegin() async throws {
        let world = try world(capacity: 6)
        var transaction = try B.baseTransaction().add(floor())
        for index in 0..<40 {
            transaction = transaction.add(try B.bubble(UInt64(index + 1), at: [20 + 12 * Float(index), 14.3], radius: 4, interest: .contact))
        }
        world.submit(transaction)
        var delivered = Set<[UInt64]>()
        var dropped = 0
        var beganCount = 0, endedCount = 0
        func collect(_ frame: WorldFrame) {
            dropped += frame.eventOverflow.droppedCount
            for event in frame.events {
                switch event {
                case .contactBegan(let a, let b, _, _, _):
                    beganCount += 1; delivered.insert([min(a.rawValue, b.rawValue), max(a.rawValue, b.rawValue)])
                case .contactEnded(let a, let b):
                    endedCount += 1
                    XCTAssertTrue(delivered.contains([min(a.rawValue, b.rawValue), max(a.rawValue, b.rawValue)]),
                        "contactEnded \(a.rawValue)-\(b.rawValue) bez wcześniejszego contactBegan")
                default: break
                }
            }
        }
        _ = await B.advance(world, steps: 40) { _, frame in collect(frame) }
        var launch = WorldTransaction()
        for index in 0..<40 { launch = launch.applyImpulse(to: ObjectID(rawValue: UInt64(index + 1)), impulse: [0, 300]) }
        world.submit(launch)
        _ = await B.advance(world, steps: 20) { _, frame in collect(frame) }
        XCTAssertGreaterThan(beganCount, 0, "przynajmniej część początków mieści się w buforze")
        XCTAssertGreaterThan(endedCount, 0, "po odskoku przynajmniej część końców mieści się w buforze, więc kontrola jest niepusta")
        XCTAssertGreaterThan(dropped, 0, "40 styków przy buforze 6 musi zwiększyć eventOverflow")
    }
}
