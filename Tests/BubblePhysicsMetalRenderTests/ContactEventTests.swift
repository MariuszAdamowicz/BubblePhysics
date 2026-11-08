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
                                   file: StaticString = #filePath, line: UInt = #line) throws {
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
        let direction = simd_normalize(second.position - first.position)
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
        try assertSingleBegan(result.events, result.frame, pair: 1, floorID)
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
            .add(B.box(1, at: [150, 15.3], half: [15, 5], role: .dynamic, interest: .contact)))
        let result = await B.advance(world, steps: 90)
        try assertSingleBegan(result.events, result.frame, pair: 1, floorID)
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

    // P-B-13: w pierwszym kroku styku para ze scalaniem dostaje contactBegan, a dopiero po nim mergeContact.
    func testMergeContactIsPrecededByContactBeganForTheSamePair() async throws {
        let world = try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let group = MergeGroupSet(rawValue: 1 << 3)
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: [100, 100], interest: [.contact, .mergeContact], mergeGroups: group))
            .add(B.bubble(2, at: [115, 100], interest: [.contact, .mergeContact], mergeGroups: group)))
        let result = await B.advance(world, steps: 5)
        let beganIndex = result.events.firstIndex { if case .contactBegan = $0 { return true }; return false }
        let mergeIndex = result.events.firstIndex { if case .mergeContact = $0 { return true }; return false }
        XCTAssertNotNil(beganIndex, "brak contactBegan")
        XCTAssertNotNil(mergeIndex, "brak mergeContact")
        if let beganIndex, let mergeIndex { XCTAssertLessThan(beganIndex, mergeIndex) }
    }

    // P-B-14: koniec kontaktu w pierwszym kroku po rozłączeniu.
    func testEndedArrivesInFirstStepsAfterSeparation() async throws {
        let world = try world()
        world.submit(try B.baseTransaction().add(floor())
            .add(B.bubble(1, at: [150, 18.3], interest: .contact)))
        _ = await B.advance(world, steps: 30)
        world.submit(WorldTransaction().applyImpulse(to: ObjectID(rawValue: 1), impulse: [0, 300]))
        var endedAt: Int?
        var events: [WorldEvent] = []
        _ = await B.advance(world, steps: 20) { index, frame in
            events += frame.events
            if endedAt == nil, !B.ended(frame.events).isEmpty { endedAt = index }
        }
        XCTAssertEqual(B.ended(events).filter { B.isPair($0.0, $0.1, 1, floorID) }.count, 1)
        let index = try XCTUnwrap(endedAt, "brak contactEnded po odskoku")
        XCTAssertLessThanOrEqual(index, 2, "koniec ma przyjść w pierwszych krokach po rozłączeniu")
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
        var beganCount = 0
        func collect(_ frame: WorldFrame) {
            dropped += frame.eventOverflow.droppedCount
            for event in frame.events {
                switch event {
                case .contactBegan(let a, let b, _, _, _):
                    beganCount += 1; delivered.insert([min(a.rawValue, b.rawValue), max(a.rawValue, b.rawValue)])
                case .contactEnded(let a, let b):
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
        XCTAssertGreaterThan(dropped, 0, "40 styków przy buforze 6 musi zwiększyć eventOverflow")
    }
}
