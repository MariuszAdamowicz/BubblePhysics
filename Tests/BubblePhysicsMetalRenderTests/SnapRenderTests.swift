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
    private let redID = RenderMaterialID(rawValue: 10), blueID = RenderMaterialID(rawValue: 11)
    private let tolerance: Float = 0.25
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func makeScene(region: WorldRectangle? = nil) throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), region: region)
        try scene.submitMaterials([(redID, RenderMaterial(color: RGBA(1, 0, 0))), (blueID, RenderMaterial(color: RGBA(0, 0, 1)))])
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
            .add(B.bubble(5, at: [8, 0], radius: 6, filter: ghost, role: .static, render: redID)))
        await scene.step(); await scene.step()
        let first = BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: B.bubbleMaterial,
                                                         renderMaterialID: redID, filter: ghost), share: 0.5)
        let second = BubbleSplitPart(result: BubbleResult(id: id(3), physicsMaterialID: B.bubbleMaterial,
                                                          renderMaterialID: blueID, filter: ghost), share: 0.5)
        scene.world.submit(WorldTransaction().splitBubble(id(5), first: first, second: second))
        let split = await scene.step()
        let object = try XCTUnwrap(split.objects[id(5)])
        // Kontur części bywa spłaszczony przy styku z drugą, więc środek rysunku porównujemy z zasięgiem poziomym jej konturu.
        let contour = try XCTUnwrap(scene.world.debugContourSnapshot()[id(5)]).map(\.x)
        let expected = (try XCTUnwrap(contour.min()) + XCTUnwrap(contour.max())) / 2
        XCTAssertGreaterThan(abs(expected - 8), 1, "część przesunęła się względem poprzedniej bańki, więc test odróżnia pozy")
        let center = try await intermediateCenter(scene, objectY: object.position.y)
        // Druga część (ID 3) jest niebieska i rysowana przed czerwoną, która zachowała ID 5, więc czerwone piksele należą tylko do niej
        // i nie są zasłonięte.
        XCTAssertEqual(try XCTUnwrap(center), expected, accuracy: tolerance,
                       "część podziału leży w swojej bieżącej pozycji, a nie w połowie drogi od starej bańki")
    }

    // P-B-52 (bańki): zawinięta bańka rysuje się przy docelowej krawędzi, bez smugi przez region.
    func testWrappedBubbleIsDrawnAtTheTargetEdge() async throws {
        let scene = try makeScene(region: WorldRectangle(min: [-15, -15], max: [15, 15]))
        let wrapped = try await wrappingBubble(scene)
        let center = try await intermediateCenter(scene)
        XCTAssertEqual(try XCTUnwrap(center), wrapped.current, accuracy: tolerance, "bez smugi przez cały region")
    }

    // A3 (G10-AC1): w klatce z krokiem zawinięcia znanym dopiero po GPU (α = 0,5) bańka też rysuje się bez interpolacji.
    func testBubbleWrappedInAStepFrameIsDrawnAtTheTargetEdgeEvenForFractionBetweenZeroAndOne() async throws {
        let scene = try makeScene(region: WorldRectangle(min: [-15, -15], max: [15, 15]))
        let wrapped = try await wrappingBubble(scene, stepFrameFraction: 0.5)
        XCTAssertEqual(scene.world.diagnostics.backlogSeconds, 0.5 / 60, accuracy: 1e-9, "α = 0,5 w klatce z krokiem")
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, wrapped.current, accuracy: tolerance, "docelowa krawędź, nie środek regionu")
    }

    // A3: ta sama klatka dla naklejki bańki, która zawinęła się w kroku niesionym przez klatkę.
    func testDecalOfABubbleWrappedInAStepFrameIsDrawnWithTheBubble() async throws {
        let scene = try makeScene(region: WorldRectangle(min: [-15, -15], max: [15, 15]))
        let image = try OffscreenRenderHarness.image(width: 1, height: 1, pixels: [[0, 255, 0, 255]])
        let decal = try Decal.image(scene.assets.register(image), scale: 0.5)
        let wrapped = try await wrappingBubble(scene, stepFrameFraction: 0.5, decal: decal)
        let center = try XCTUnwrap(scene.renderedCenterX(where: { $0[1] > 128 && $0[0] < 100 && $0[2] < 100 }))
        XCTAssertEqual(center, wrapped.current, accuracy: tolerance, "naklejka przy docelowej krawędzi razem z bańką")
    }

    /// Bańka (promień 1, 60 jednostek na sekundę) zawija się przez prawą krawędź. Bez `stepFrameFraction` kończy po kroku
    /// zawinięcia; z nim ostatnia klatka z kroku zawinięcia jest wyrenderowana z tym α (nadwyżka 0,5 kroku przed klatką).
    private func wrappingBubble(_ scene: RenderTestScene, stepFrameFraction: Double? = nil,
                                decal: Decal? = nil) async throws -> (previous: Float, current: Float) {
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [8, 0], radius: 1, velocity: [60, 0], filter: ghost, regionExitPolicy: .wrap, render: redID,
                          decal: decal)))
        await scene.step()
        var previous: Float = 8, current: Float = 8
        if let stepFrameFraction {
            // Nadwyżka w akumulatorze: każda następna klatka z krokiem zostawia w nim `stepFrameFraction` kroku.
            await scene.world.advance(by: stepFrameFraction / 60)
            for _ in 0..<30 {
                previous = current
                let result = try await scene.advanceRendering(by: 1.0 / 60)
                current = try XCTUnwrap(result.frame.objects[id(1)]).position.x
                if current < previous - 5 { return (previous, current) }
            }
            XCTFail("bańka nie zawinęła się")
            return (previous, current)
        }
        for _ in 0..<30 where current >= previous {
            previous = current
            let stepped = await scene.step()
            current = try XCTUnwrap(stepped.objects[id(1)]).position.x
        }
        XCTAssertLessThan(current, previous - 5, "krok z zawinięciem")
        return (previous, current)
    }

    /// Koło (promień 1, 60 jednostek na sekundę) zawija się przez prawą krawędź regionu w klatce z krokiem, w której α = 0,5
    /// (nadwyżka pół kroku w akumulatorze). Zwraca pozę sprzed kroku zawinięcia i po nim.
    private func wrappingBody(_ scene: RenderTestScene, decal: Decal? = nil) async throws -> (before: Float, wrappedAt: Float) {
        scene.world.submit(try WorldTransaction()
            .add(B.circle(1, at: [8, 0], radius: 1, velocity: [60, 0], filter: ghost, regionExitPolicy: .wrap, render: redID,
                          decal: decal)))
        await scene.step()
        await scene.world.advance(by: 0.5 / 60)
        var before: Float = 8, wrappedAt: Float = 8
        for _ in 0..<30 {
            before = wrappedAt
            let result = try await scene.advanceRendering(by: 1.0 / 60)
            wrappedAt = try XCTUnwrap(result.frame.objects[id(1)]).position.x
            if wrappedAt < before - 5 { break }
        }
        XCTAssertLessThan(wrappedAt, before - 5, "krok z zawinięciem")
        XCTAssertEqual(scene.world.diagnostics.backlogSeconds, 0.5 / 60, accuracy: 1e-9, "α = 0,5 w klatce z krokiem")
        return (before, wrappedAt)
    }

    // A3 (G10-AC1): bryła zawinięta w klatce z krokiem (α = 0,5; zawinięcie znane dopiero po GPU) rysuje się bez interpolacji,
    // przy docelowej krawędzi, a nie w środku regionu ani za krawędzią.
    func testBodyWrappedInAStepFrameIsDrawnAtTheTargetEdgeWithoutInterpolation() async throws {
        let scene = try makeScene(region: WorldRectangle(min: [-15, -15], max: [15, 15]))
        let wrapped = try await wrappingBody(scene)
        let center = try XCTUnwrap(scene.renderedCenterX())
        XCTAssertEqual(center, wrapped.wrappedAt, accuracy: tolerance, "docelowa krawędź, nie ekstrapolacja ani środek regionu")
    }

    // A3: naklejka bryły zawiniętej w klatce z krokiem leży z bryłą przy docelowej krawędzi.
    func testDecalOfABodyWrappedInAStepFrameIsDrawnWithTheBody() async throws {
        let scene = try makeScene(region: WorldRectangle(min: [-15, -15], max: [15, 15]))
        let image = try OffscreenRenderHarness.image(width: 1, height: 1, pixels: [[0, 255, 0, 255]])
        let decal = try Decal.image(scene.assets.register(image), scale: 0.5)
        let wrapped = try await wrappingBody(scene, decal: decal)
        let center = try XCTUnwrap(scene.renderedCenterX(where: { $0[1] > 128 && $0[0] < 100 && $0[2] < 100 }))
        XCTAssertEqual(center, wrapped.wrappedAt, accuracy: tolerance, "naklejka przy docelowej krawędzi razem z bryłą")
    }
}
