import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// P-B-27 (G11-AC4): ciągła detekcja kolizji bryła–bryła. Bryła grubości 4 jednostek lecąca 12 jednostek na krok nie przenika
/// przez statyczną grubości 4, a dwie takie naprzeciw siebie nie mijają się; bez błędu klatki (dawniej `guardFailure`).
@MainActor
final class RigidCCDTests: XCTestCase {
    private typealias B = SceneBuilders
    private let speed: Float = 720 // 12 jednostek na krok przy 1/60 s

    private func makeWorld(gravity: WorldPoint = .zero) throws -> BubbleWorld {
        try B.makeWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
                        region: WorldRectangle(min: [0, 0], max: [600, 600]), gravity: gravity)
    }

    // Spadająca bryła uderza w cienką statyczną podłogę. Pod grawitacją styk trwa: jeden początek, żadnego końca (jak P-B-12).
    func testFastDynamicBoxDoesNotTunnelThroughThinStaticFloor() async throws {
        let world = try makeWorld(gravity: [0, -400])
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [300, 100], half: [80, 2], role: .static))
            .add(B.box(1, at: [300, 164], half: [10, 2], role: .dynamic, velocity: [0, -speed], interest: .contact)))
        var events: [WorldEvent] = []
        var lowest: Float = .infinity
        let result = await B.advance(world, steps: 120) { _, frame in
            events += frame.events
            if let box = frame.objects[ObjectID(rawValue: 1)] { lowest = min(lowest, box.position.y) }
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "klatka nie może się nie udać")
        XCTAssertGreaterThan(lowest, 100 + 2 + 2 - 0.5, "bryła nie może zejść poniżej górnej krawędzi podłogi")
        XCTAssertEqual(try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 1)]).position.y, 104, accuracy: 0.6)
        let began = B.began(events).filter { B.isPair($0.a, $0.b, 1, 2) }
        XCTAssertEqual(began.count, 1, "dokładnie jeden contactBegan przy trwałym styku")
        XCTAssertTrue(B.ended(events).isEmpty, "trwały styk nie daje contactEnded")
    }

    // Dwie takie bryły lecące naprzeciw siebie: nie zamieniają się miejscami i nie przenikają.
    func testTwoFastDynamicBoxesHeadOnDoNotPassThroughEachOther() async throws {
        let world = try makeWorld()
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: [100, 300], half: [2, 20], role: .dynamic, velocity: [speed, 0], interest: .contact))
            .add(B.box(2, at: [220, 300], half: [2, 20], role: .dynamic, velocity: [-speed, 0])))
        var events: [WorldEvent] = []
        var worstGap: Float = .infinity
        let result = await B.advance(world, steps: 60) { _, frame in
            events += frame.events
            if let a = frame.objects[ObjectID(rawValue: 1)], let b = frame.objects[ObjectID(rawValue: 2)] {
                worstGap = min(worstGap, b.position.x - a.position.x)
            }
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "klatka nie może się nie udać")
        XCTAssertGreaterThan(worstGap, 4 - 0.5, "środki nie mogą się minąć ani zejść bliżej niż grubość")
        XCTAssertEqual(B.began(events).filter { B.isPair($0.a, $0.b, 1, 2) }.count, 1)
        XCTAssertTrue(B.ended(events).filter { B.isPair($0.0, $0.1, 1, 2) }.isEmpty, "trwały styk nie daje contactEnded")
        let a = try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 1)]), b = try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 2)])
        XCTAssertLessThan(a.position.x, b.position.x)
    }

    // Wariant ze statyczną w poziomie: bryła nie przechodzi na drugą stronę.
    func testFastDynamicBoxDoesNotTunnelThroughThinStaticWall() async throws {
        let world = try makeWorld()
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [300, 300], half: [2, 60], role: .static))
            .add(B.box(1, at: [120, 300], half: [2, 20], role: .dynamic, velocity: [speed, 0])))
        var rightmost: Float = -.infinity
        _ = await B.advance(world, steps: 60) { _, frame in
            if let box = frame.objects[ObjectID(rawValue: 1)] { rightmost = max(rightmost, box.position.x) }
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertLessThan(rightmost, 300 - 2 - 2 + 0.5, "bryła zostaje po swojej stronie ściany")
    }

    // Nieruchoma i kinematyczna bryła nie cofa się: jest przeszkodą dla szybkiej dynamicznej.
    func testKinematicBodyIsNotPushedBackByCCDAndStopsFastBox() async throws {
        let world = try makeWorld()
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [300, 300], half: [2, 60], role: .kinematic))
            .setKinematicDrive(ObjectID(rawValue: 2), drive: .velocity(linear: [0, 0], angular: 0))
            .add(B.box(1, at: [120, 300], half: [2, 20], role: .dynamic, velocity: [speed, 0])))
        var rightmost: Float = -.infinity
        let result = await B.advance(world, steps: 60) { _, frame in
            if let box = frame.objects[ObjectID(rawValue: 1)] { rightmost = max(rightmost, box.position.x) }
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertLessThan(rightmost, 300 - 2 - 2 + 0.5)
        XCTAssertEqual(try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 2)]).position, [300, 300],
                       "kinematyczna nie cofa się ani nie przesuwa")
    }

    // CCD obejmuje też koło i kapsułę (rdzeń z promieniem): szybkie koło nie przechodzi przez cienką bryłę dynamiczną,
    // a dwie szybkie kapsuły naprzeciw siebie nie mijają się.
    func testFastCircleAndCapsulesDoNotTunnel() async throws {
        let world = try makeWorld()
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [300, 300], half: [2, 60], role: .dynamic))
            .add(B.circle(1, at: [120, 300], radius: 2, velocity: [speed, 0]))
            .add(B.capsule(3, at: [100, 100], halfLength: 5, radius: 2, role: .dynamic, velocity: [speed, 0]))
            .add(B.capsule(4, at: [220, 100], halfLength: 5, radius: 2, role: .dynamic, velocity: [-speed, 0])))
        var circleRightOfBox = false, capsulesCrossed = false
        let result = await B.advance(world, steps: 60) { _, frame in
            if let c = frame.objects[ObjectID(rawValue: 1)], let b = frame.objects[ObjectID(rawValue: 2)], c.position.x > b.position.x { circleRightOfBox = true }
            if let a = frame.objects[ObjectID(rawValue: 3)], let b = frame.objects[ObjectID(rawValue: 4)], a.position.x > b.position.x { capsulesCrossed = true }
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue, "klatka nie może się nie udać")
        XCTAssertFalse(circleRightOfBox, "koło nie może minąć cienkiej bryły")
        XCTAssertFalse(capsulesCrossed, "kapsuły nie mogą się minąć")
        XCTAssertLessThan(try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 3)]).position.x,
                          try XCTUnwrap(result.frame.objects[ObjectID(rawValue: 4)]).position.x)
    }
}
