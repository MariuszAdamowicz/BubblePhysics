import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

/// P-B-11 (G7-AC1): obiekty z rozłącznymi maskami nie mają kontaktu, a z domyślnymi mają.
@MainActor
final class CollisionFilterWorldTests: XCTestCase {
    private typealias B = SceneBuilders
    private let onlyCategory2 = CollisionFilter(category: 1, mask: 1 << 1)

    private func position(_ frame: WorldFrame, _ id: UInt64) throws -> WorldPoint {
        try XCTUnwrap(frame.objects[ObjectID(rawValue: id)], "brak obiektu \(id)").position
    }

    func testBubblesWithDisjointMasksPassThroughEachOtherWhileDefaultsCollide() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: [100, 100], radius: 10, velocity: [60, 0], filter: onlyCategory2))
            .add(B.bubble(2, at: [200, 100], radius: 10, velocity: [-60, 0], filter: onlyCategory2))
            .add(B.bubble(3, at: [100, 200], radius: 10, velocity: [60, 0]))
            .add(B.bubble(4, at: [200, 200], radius: 10, velocity: [-60, 0])))
        let result = await B.advance(world, steps: 90)
        XCTAssertGreaterThan(try position(result.frame, 1).x, try position(result.frame, 2).x + 20,
            "bańki z rozłącznymi maskami mają się minąć")
        XCTAssertLessThan(try position(result.frame, 3).x, try position(result.frame, 4).x,
            "bańki z domyślnym filtrem nie mogą się minąć")
    }

    // Kategoria 1 bańki 1 nie jest w masce bańki 2 (4), więc brak kolizji, choć kategoria 2 bańki 2 jest w masce bańki 1.
    func testCollisionRequiresBothMasksToAcceptTheOtherCategory() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.bubble(1, at: [100, 100], radius: 10, velocity: [60, 0], filter: CollisionFilter(category: 1, mask: .max)))
            .add(B.bubble(2, at: [200, 100], radius: 10, velocity: [-60, 0], filter: CollisionFilter(category: 2, mask: 4))))
        let result = await B.advance(world, steps: 90)
        XCTAssertGreaterThan(try position(result.frame, 1).x, try position(result.frame, 2).x + 20)
    }

    func testBubbleWithDisjointMaskPassesStaticWallWhileDefaultBubbleIsStopped() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(10, at: [300, 100], half: [5, 60], filter: CollisionFilter(category: 1, mask: 1)))
            .add(B.box(11, at: [300, 220], half: [5, 60]))
            .add(B.bubble(1, at: [200, 100], radius: 8, velocity: [80, 0], filter: onlyCategory2))
            .add(B.bubble(2, at: [200, 220], radius: 8, velocity: [80, 0])))
        let result = await B.advance(world, steps: 120)
        XCTAssertGreaterThan(try position(result.frame, 1).x, 310, "bańka z rozłączną maską ma przejść przez ścianę")
        XCTAssertLessThan(try position(result.frame, 2).x, 295, "bańka z domyślnym filtrem ma zostać przed ścianą")
    }

    // Ścieżka bańka–bryła (nativeRigidEmitCandidates): dynamiczna i kinematyczna bryła z domyślnym filtrem.
    func testBubbleWithDisjointMaskPassesDynamicAndKinematicBodiesWhileDefaultBubbleIsStopped() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(10, at: [200, 40], half: [10, 20], role: .dynamic))
            .add(B.box(11, at: [200, 120], half: [10, 20], role: .kinematic))
            .add(B.box(12, at: [200, 200], half: [10, 20], role: .dynamic))
            .add(B.box(13, at: [200, 260], half: [10, 20], role: .kinematic))
            .add(B.bubble(1, at: [100, 40], radius: 10, velocity: [80, 0], filter: onlyCategory2))
            .add(B.bubble(2, at: [100, 120], radius: 10, velocity: [80, 0], filter: onlyCategory2))
            .add(B.bubble(3, at: [100, 200], radius: 10, velocity: [80, 0]))
            .add(B.bubble(4, at: [100, 260], radius: 10, velocity: [80, 0])))
        let result = await B.advance(world, steps: 120)
        XCTAssertGreaterThan(try position(result.frame, 1).x, 225, "bańka z rozłączną maską ma przejść przez dynamiczną bryłę")
        XCTAssertGreaterThan(try position(result.frame, 2).x, 225, "bańka z rozłączną maską ma przejść przez kinematyczną bryłę")
        XCTAssertLessThan(try position(result.frame, 3).x, try position(result.frame, 12).x, "domyślna bańka nie mija dynamicznej bryły")
        XCTAssertLessThan(try position(result.frame, 4).x, 190, "domyślna bańka zostaje przed kinematyczną bryłą")
    }

    // Ścieżka bryła dynamiczna–wielokąt statyczny (nativeRigidPredict, nativeRigidGuardWalls i kandydaci brył).
    func testDynamicBodyWithDisjointMaskPassesStaticPolygonWhileDefaultBodyIsStopped() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(10, at: [300, 100], half: [5, 60]))
            .add(B.box(11, at: [300, 220], half: [5, 60]))
            .add(B.box(1, at: [200, 100], half: [10, 10], role: .dynamic, velocity: [80, 0], filter: onlyCategory2))
            .add(B.box(2, at: [200, 220], half: [10, 10], role: .dynamic, velocity: [80, 0])))
        let result = await B.advance(world, steps: 120)
        XCTAssertGreaterThan(try position(result.frame, 1).x, 320, "bryła z rozłączną maską ma przejść przez statyczny wielokąt")
        XCTAssertLessThan(try position(result.frame, 2).x, 290, "bryła z domyślnym filtrem ma zostać przed statycznym wielokątem")
    }

    func testDynamicBoxesWithDisjointMasksPassThroughEachOther() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: [100, 100], half: [10, 10], role: .dynamic, velocity: [60, 0], filter: onlyCategory2))
            .add(B.box(2, at: [200, 100], half: [10, 10], role: .dynamic, velocity: [-60, 0], filter: onlyCategory2))
            .add(B.box(3, at: [100, 200], half: [10, 10], role: .dynamic, velocity: [60, 0]))
            .add(B.box(4, at: [200, 200], half: [10, 10], role: .dynamic, velocity: [-60, 0])))
        let result = await B.advance(world, steps: 90)
        XCTAssertGreaterThan(try position(result.frame, 1).x, try position(result.frame, 2).x + 20)
        XCTAssertLessThan(try position(result.frame, 3).x, try position(result.frame, 4).x)
    }
}
