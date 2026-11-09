import BubblePhysics
import Metal
import XCTest

/// P-B-52: obiekt utworzony, zawinięty, scalony, podzielony albo zastąpiony w ostatnim kroku rysuje się bez interpolacji,
/// w stanie bieżącego kroku. Test: w klatce pośredniej (α = 0,5) środek rysunku leży w bieżącej pozycji obiektu, a nie w
/// połowie drogi od jego poprzedniej pozy.
@MainActor
final class SnapRenderTests: XCTestCase {
    private typealias B = SceneBuilders
    private let ghost = RenderTestScene.ghost
    private let redID = RenderMaterialID(rawValue: 10)
    private let tolerance: Float = 0.25
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func makeScene(region: WorldRectangle? = nil) throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), region: region)
        try scene.submitMaterials([(redID, RenderMaterial(color: RGBA(1, 0, 0)))])
        return scene
    }

    /// Środek rysunku w wierszu obiektu (y świata → wiersz obrazu) po klatce pośredniej.
    private func intermediateCenter(_ scene: RenderTestScene, objectY: Float = 0) async throws -> Float? {
        try await scene.advanceRendering(by: 1.0 / 120)
        return scene.renderedCenterX(row: Int((128 - objectY * 6.4).rounded()))
    }

    func testCreatedObjectIsDrawnAtItsCurrentPose() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: [-10, 0], half: [1, 1], role: .kinematic, filter: ghost, render: redID))
            .setKinematicDrive(id(1), drive: .velocity(linear: [60, 0], angular: 0)))
        let created = await scene.step()
        let now = try XCTUnwrap(created.objects[id(1)]).position.x
        let center = try await intermediateCenter(scene)
        XCTAssertEqual(try XCTUnwrap(center), now, accuracy: tolerance)
    }

    func testWrappedBodyIsDrawnAtTheTargetEdge() async throws {
        let scene = try makeScene(region: WorldRectangle(min: [-15, -15], max: [15, 15]))
        scene.world.submit(try WorldTransaction()
            .add(B.circle(1, at: [8, 0], radius: 1, velocity: [60, 0], filter: ghost, regionExitPolicy: .wrap, render: redID)))
        var previous: Float = 8, current: Float = 8
        for _ in 0..<12 where current >= previous {
            previous = current
            let stepped = await scene.step()
            current = try XCTUnwrap(stepped.objects[id(1)]).position.x
        }
        XCTAssertLessThan(current, previous - 5, "krok z zawinięciem")
        let center = try await intermediateCenter(scene)
        XCTAssertEqual(try XCTUnwrap(center), current, accuracy: tolerance, "bez smugi przez cały region")
    }

    func testReplacedObjectIsDrawnAtItsNewPose() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: [-10, 0], half: [1, 1], role: .static, filter: ghost, render: redID)))
        await scene.step(); await scene.step()
        scene.world.submit(try WorldTransaction()
            .replace(id(1), with: B.box(1, at: [8, 0], half: [1, 1], role: .static, filter: ghost, render: redID)))
        await scene.step()
        let center = try await intermediateCenter(scene)
        XCTAssertEqual(try XCTUnwrap(center), 8, accuracy: tolerance, "nowa poza, bez smugi od starej")
    }

    func testMergedBubbleWithAnExistingIDIsDrawnAtItsCurrentPose() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-6, 0], radius: 5, filter: ghost, role: .static, render: redID))
            .add(B.bubble(2, at: [6, 0], radius: 5, filter: ghost, role: .static, render: redID)))
        await scene.step(); await scene.step()
        let result = BubbleResult(id: id(1), physicsMaterialID: B.bubbleMaterial, renderMaterialID: redID, filter: ghost)
        scene.world.submit(WorldTransaction().mergeBubbles([id(1), id(2)], result: result))
        let merged = await scene.step()
        let object = try XCTUnwrap(merged.objects[id(1)])
        XCTAssertNil(merged.objects[id(2)])
        XCTAssertEqual(object.position.x, 0, accuracy: 3, "wynik scalenia leży między źródłami")
        let center = try await intermediateCenter(scene, objectY: object.position.y)
        XCTAssertEqual(try XCTUnwrap(center), object.position.x, accuracy: tolerance, "bez smugi od poprzedniej bańki 1")
    }

    func testSplitBubbleKeepingItsIDIsDrawnAtItsCurrentPose() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [8, 0], radius: 6, filter: ghost, role: .static, render: redID)))
        await scene.step(); await scene.step()
        let first = BubbleSplitPart(result: BubbleResult(id: id(1), physicsMaterialID: B.bubbleMaterial,
                                                         renderMaterialID: redID, filter: ghost), share: 0.5)
        let second = BubbleSplitPart(result: BubbleResult(id: id(3), physicsMaterialID: B.bubbleMaterial,
                                                          renderMaterialID: redID, filter: ghost), share: 0.5)
        scene.world.submit(WorldTransaction().splitBubble(id(1), first: first, second: second))
        let split = await scene.step()
        let object = try XCTUnwrap(split.objects[id(1)])
        let center = try await intermediateCenter(scene, objectY: object.position.y)
        let measured = try XCTUnwrap(center)
        XCTAssertEqual(measured, object.position.x, accuracy: 3.5, "część podziału leży w swojej bieżącej pozycji")
    }
}
