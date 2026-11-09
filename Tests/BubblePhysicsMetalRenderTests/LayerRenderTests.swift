import BubblePhysics
import Metal
import XCTest

/// P-B-40, P-B-62, P-B-73, P-B-74 (G4-AC1): kolejność rysowania warstw i obiektów. Obiekty rozróżnia kolor materiału,
/// a dwie białe tekstury 1×1 tylko łamią ciągi rysowania, więc testy przechodzą bez próbkowania tekstur.
@MainActor
final class LayerRenderTests: XCTestCase {
    private typealias B = SceneBuilders
    private let red = RGBA(1, 0, 0, 1), green = RGBA(0, 1, 0, 1), blue = RGBA(0, 0, 1, 1)
    private let redID = RenderMaterialID(rawValue: 10), greenID = RenderMaterialID(rawValue: 11),
                blueID = RenderMaterialID(rawValue: 12)
    private let ghost = RenderTestScene.ghost
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func makeScene() throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try scene.submitMaterials([(redID, RenderMaterial(color: red)), (greenID, RenderMaterial(color: green)),
                                   (blueID, RenderMaterial(color: blue))])
        return scene
    }

    // P-B-40: bańka na wyższej warstwie przykrywa bryłę, choć bryła w obrębie warstwy rysuje się po bańce.
    func testBubbleOnHigherLayerCoversRigidBody() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: redID, layer: 1))
            .add(B.box(2, at: .zero, half: [6, 6], filter: ghost, render: greenID, layer: 0)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], red, "wspólny obszar: wyższa warstwa")
        scene.assertPixel([7, 0], red, "tylko bańka")
        scene.assertPixel([14, 0], RGBA(0, 0, 0), "tło poza obiektami")
    }

    // P-B-40: w jednej warstwie bryła przykrywa bańkę, bez względu na ObjectID.
    func testInTheSameLayerRigidBodyCoversBubble() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(9, at: .zero, radius: 8, filter: ghost, role: .static, render: redID))
            .add(B.box(2, at: .zero, half: [6, 6], filter: ghost, render: greenID)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], green, "wspólny obszar: bryła nad bańką")
        scene.assertPixel([7, 0], red, "tylko bańka")
        scene.assertPixel([5, 5], green, "tylko bryła")
    }

    // P-B-40: warstwy rosną, niezależnie od ObjectID i od kolejności dodania; ujemna warstwa leży pod zerową.
    func testLayersDrawAscendingWhateverTheObjectIDsAndSigns() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(30, at: .zero, radius: 8, filter: ghost, role: .static, render: redID, layer: -3))
            .add(B.bubble(10, at: .zero, radius: 8, filter: ghost, role: .static, render: greenID, layer: 4))
            .add(B.bubble(20, at: .zero, radius: 8, filter: ghost, role: .static, render: blueID, layer: 0)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], green, "najwyższa warstwa 4 mimo najmniejszego ObjectID")
    }

    // P-B-62: setLayer zmienia kolejność rysowania w pierwszej klatce z potwierdzeniem.
    func testSetLayerChangesDrawOrderInTheFirstConfirmedFrame() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: redID))
            .add(B.bubble(2, at: .zero, radius: 8, filter: ghost, role: .static, render: greenID)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], green, "przed zmianą wygrywa większy ObjectID")
        let token = scene.world.submit(try WorldTransaction().setLayer(id(1), layer: 3))
        let frame = await scene.step()
        XCTAssertTrue(frame.transactionReceipts.contains { $0.token == token }, "potwierdzenie w tej samej klatce")
        try await scene.render()
        scene.assertPixel([0, 0], red, "obiekt 1 na warstwie 3 leży nad obiektem 2")
    }

    // P-B-62: odrzucona transakcja nie zmienia kolejności rysowania.
    func testRejectedSetLayerTransactionKeepsDrawOrder() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: redID))
            .add(B.bubble(2, at: .zero, radius: 8, filter: ghost, role: .static, render: greenID)))
        await scene.step()
        let token = scene.world.submit(try WorldTransaction().setLayer(id(1), layer: 3).remove(id(999)))
        let frame = await scene.step()
        XCTAssertTrue(frame.events.contains { event in
            if case .transactionRejected(let rejected, _) = event { return rejected == token }
            return false
        })
        try await scene.render()
        scene.assertPixel([0, 0], green, "transakcja atomowo odrzucona, więc warstwa 1 bez zmian")
    }

    // P-B-73: czujnik i pole sił nie mają pikseli, a bańka obok jest narysowana.
    func testSensorAndForceFieldAreNotDrawn() async throws {
        let scene = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-10, 0], radius: 4, filter: ghost, role: .static, render: redID))
            .add(.sensor(try SensorDescriptor(id: id(2), position: [10, 0], geometry: .circle(radius: 4))))
            .add(.forceField(try ForceFieldDescriptor(id: id(3), position: [0, 12], geometry: .circle(radius: 4),
                field: .directional(force: [0, 0])))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-10, 0], red, "bańka")
        scene.assertPixel([10, 0], RGBA(0, 0, 0), "czujnik")
        scene.assertPixel([0, 12], RGBA(0, 0, 0), "pole sił")
    }

    // P-B-74: bańki o rosnących ObjectID na przemian w trybie nieprzezroczystym i alfa. Kolejność mieszania zgodna z ObjectID:
    // 1 nieprzezroczysty czerwony, 2 alfa zielony 0,5, 3 nieprzezroczysty niebieski, 4 alfa czerwony 0,5.
    func testBubblesAlternatingOpaqueAndAlphaFollowObjectID() async throws {
        let scene = try makeScene()
        let alphaGreen = RenderMaterialID(rawValue: 21), alphaRed = RenderMaterialID(rawValue: 22)
        scene.world.submit(try WorldTransaction()
            .updateRenderMaterial(alphaGreen, material: RenderMaterial(color: RGBA(0, 1, 0, 0.5), blend: .alpha))
            .updateRenderMaterial(alphaRed, material: RenderMaterial(color: RGBA(1, 0, 0, 0.5), blend: .alpha)))
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: redID))
            .add(B.bubble(2, at: .zero, radius: 8, filter: ghost, role: .static, render: alphaGreen))
            .add(B.bubble(3, at: .zero, radius: 8, filter: ghost, role: .static, render: blueID))
            .add(B.bubble(4, at: .zero, radius: 8, filter: ghost, role: .static, render: alphaRed)))
        await scene.step()
        try await scene.render()
        // ((czerwony → 0,5 zielony → niebieski) → 0,5 czerwony) = 0,5 czerwony + 0,5 niebieski.
        scene.assertPixel([0, 0], RGBA(0.5, 0, 0.5), "kolejność mieszania po ObjectID")
    }

    // P-B-74: to samo dla brył.
    func testBodiesAlternatingOpaqueAndAlphaFollowObjectID() async throws {
        let scene = try makeScene()
        let alphaGreen = RenderMaterialID(rawValue: 21), alphaRed = RenderMaterialID(rawValue: 22)
        scene.world.submit(try WorldTransaction()
            .updateRenderMaterial(alphaGreen, material: RenderMaterial(color: RGBA(0, 1, 0, 0.5), blend: .alpha))
            .updateRenderMaterial(alphaRed, material: RenderMaterial(color: RGBA(1, 0, 0, 0.5), blend: .alpha)))
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: .zero, half: [6, 6], filter: ghost, render: redID))
            .add(B.circle(2, at: .zero, radius: 6, role: .static, filter: ghost, render: alphaGreen))
            .add(B.box(3, at: .zero, half: [6, 6], filter: ghost, render: blueID))
            .add(B.capsule(4, at: .zero, halfLength: 3, radius: 3, role: .static, filter: ghost, render: alphaRed)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], RGBA(0.5, 0, 0.5), "kolejność mieszania po ObjectID")
    }

    // P-B-74: bańki z dwiema teksturami na przemian; grupowanie po teksturze nie może zmienić kolejności.
    func testBubblesWithTwoTexturesFollowObjectID() async throws {
        let scene = try makeScene()
        let first = try scene.assets.register(OffscreenRenderHarness.whiteImage())
        let second = try scene.assets.register(OffscreenRenderHarness.whiteImage())
        let textured: [(RenderMaterialID, TextureID, RGBA)] = [
            (RenderMaterialID(rawValue: 31), first, red), (RenderMaterialID(rawValue: 32), second, green),
            (RenderMaterialID(rawValue: 33), first, blue)]
        var materials = WorldTransaction()
        for (materialID, texture, color) in textured {
            materials = materials.updateRenderMaterial(materialID, material: try RenderMaterial(texture: texture, color: color))
        }
        scene.world.submit(materials)
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: textured[0].0))
            .add(B.bubble(2, at: .zero, radius: 8, filter: ghost, role: .static, render: textured[1].0))
            .add(B.bubble(3, at: .zero, radius: 8, filter: ghost, role: .static, render: textured[2].0)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], blue, "ObjectID 3 nad 2 nad 1, choć 1 i 3 dzielą teksturę")
    }

    // P-B-74: to samo dla brył.
    func testBodiesWithTwoTexturesFollowObjectID() async throws {
        let scene = try makeScene()
        let first = try scene.assets.register(OffscreenRenderHarness.whiteImage())
        let second = try scene.assets.register(OffscreenRenderHarness.whiteImage())
        let textured: [(RenderMaterialID, TextureID, RGBA)] = [
            (RenderMaterialID(rawValue: 31), first, red), (RenderMaterialID(rawValue: 32), second, green),
            (RenderMaterialID(rawValue: 33), first, blue)]
        var materials = WorldTransaction()
        for (materialID, texture, color) in textured {
            materials = materials.updateRenderMaterial(materialID, material: try RenderMaterial(texture: texture, color: color))
        }
        scene.world.submit(materials)
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: .zero, half: [6, 6], filter: ghost, render: textured[0].0))
            .add(B.circle(2, at: .zero, radius: 6, role: .static, filter: ghost, render: textured[1].0))
            .add(B.box(3, at: .zero, half: [6, 6], filter: ghost, render: textured[2].0)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], blue, "ObjectID 3 nad 2 nad 1, choć 1 i 3 dzielą teksturę")
    }
}
