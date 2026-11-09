import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import Metal
import XCTest

/// P-B-35 (kolor, tryby mieszania, obrys), P-B-42 (alfa 0,8), P-B-39 (rejestr renderera): materiał renderu bez próbkowania tekstur.
@MainActor
final class MaterialColorRenderTests: XCTestCase {
    private typealias B = SceneBuilders
    private let ghost = RenderTestScene.ghost
    private let black = RGBA(0, 0, 0)
    private let materialA = RenderMaterialID(rawValue: 10), materialB = RenderMaterialID(rawValue: 11)

    private func makeScene(_ materials: [(RenderMaterialID, RenderMaterial)]) throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        try scene.submitMaterials(materials)
        return scene
    }

    // P-B-35: kolor materiału maluje wnętrze bańki i każdej bryły; poza obiektami zostaje tło.
    func testMaterialColorPaintsBubbleAndRigidBodies() async throws {
        let color = RGBA(0.2, 0.4, 0.6)
        let scene = try makeScene([(materialA, RenderMaterial(color: color))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-12, 10], radius: 4, filter: ghost, role: .static, render: materialA))
            .add(B.box(2, at: [12, 10], half: [4, 4], filter: ghost, render: materialA))
            .add(B.circle(3, at: [-12, -10], radius: 4, role: .static, filter: ghost, render: materialA))
            .add(B.capsule(4, at: [12, -10], halfLength: 3, radius: 3, role: .static, filter: ghost, render: materialA)))
        await scene.step()
        try await scene.render()
        for (name, center) in [("bańka", WorldPoint(-12, 10)), ("wielokąt", WorldPoint(12, 10)),
                               ("koło", WorldPoint(-12, -10)), ("kapsuła", WorldPoint(12, -10))] {
            scene.assertPixel(center, color, name)
        }
        scene.assertPixel([0, 0], black, "tło")
    }

    // P-B-35: tryb nieprzezroczysty ignoruje alfę koloru.
    func testOpaqueBlendIgnoresColorAlpha() async throws {
        let scene = try makeScene([(materialA, RenderMaterial(color: RGBA(0.8, 0.4, 0.2, 0.25), blend: .opaque))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 6, filter: ghost, role: .static, render: materialA)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], RGBA(0.8, 0.4, 0.2))
    }

    // P-B-42: nakładka z alfą 0,8 daje 0,8·nakładka + 0,2·spód, ±2/255.
    func testAlphaBlendEightyPercentOverlay() async throws {
        let under = RGBA(0, 1, 0), overlay = RGBA(0.5, 0.25, 1, 0.8)
        let scene = try makeScene([(materialA, RenderMaterial(color: under)),
                                   (materialB, RenderMaterial(color: overlay, blend: .alpha))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: materialA))
            .add(B.bubble(2, at: .zero, radius: 4, filter: ghost, role: .static, render: materialB)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], RGBA(0.8 * 0.5, 0.8 * 0.25 + 0.2, 0.8), "nakładka nad spodem")
        scene.assertPixel([6, 0], under, "poza nakładką widać sam spód")
    }

    // P-B-42: to samo dla bryły nakładki.
    func testAlphaBlendOverlayOnRigidBody() async throws {
        let under = RGBA(0, 1, 0), overlay = RGBA(1, 0, 0, 0.8)
        let scene = try makeScene([(materialA, RenderMaterial(color: under)),
                                   (materialB, RenderMaterial(color: overlay, blend: .alpha))])
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: .zero, half: [8, 8], filter: ghost, render: materialA))
            .add(B.box(2, at: .zero, half: [4, 4], filter: ghost, render: materialB)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], RGBA(0.8, 0.2, 0), "nakładka nad spodem")
        scene.assertPixel([6, 0], under, "poza nakładką widać sam spód")
    }

    // P-B-35: tryb addytywny dodaje kolor do tego, co pod spodem.
    func testAdditiveBlendAddsToWhatIsBelow() async throws {
        let scene = try makeScene([(materialA, RenderMaterial(color: RGBA(0.2, 0.3, 0.1))),
                                   (materialB, RenderMaterial(color: RGBA(0.5, 0.25, 0.5), blend: .additive))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: materialA))
            .add(B.bubble(2, at: .zero, radius: 4, filter: ghost, role: .static, render: materialB)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], RGBA(0.7, 0.55, 0.6), "suma kolorów")
        scene.assertPixel([6, 0], RGBA(0.2, 0.3, 0.1), "poza nakładką spód")
    }

    // P-B-35: obrys o zadanej szerokości w jednostkach świata leży wewnątrz konturu bańki.
    func testBubbleOutlineLiesInsideTheContourWithTheGivenWidth() async throws {
        let fill = RGBA(0, 0, 1), outline = RGBA(1, 1, 0)
        let scene = try makeScene([(materialA, RenderMaterial(color: fill, outline: RenderOutline(color: outline, width: 2)))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: materialA)))
        await scene.step()
        try await scene.render()
        for direction in [WorldPoint(1, 0), WorldPoint(0, 1), WorldPoint(-1, 0), WorldPoint(0, -1)] {
            scene.assertPixel(direction * 7.2, outline, "pas obrysu \(direction)")
            scene.assertPixel(direction * 5.2, fill, "wypełnienie \(direction)")
            scene.assertPixel(direction * 8.6, black, "poza konturem \(direction)")
        }
    }

    // P-B-35: obrys wielokąta i koła; szerokość mierzona od krawędzi do wnętrza.
    func testRigidBodyOutlineLiesInsideTheShapeWithTheGivenWidth() async throws {
        let fill = RGBA(0, 0, 1), outline = RGBA(1, 1, 0)
        let scene = try makeScene([(materialA, RenderMaterial(color: fill, outline: RenderOutline(color: outline, width: 3)))])
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: [-10, 0], half: [8, 8], filter: ghost, render: materialA))
            .add(B.circle(2, at: [12, 0], radius: 7, role: .static, filter: ghost, render: materialA)))
        await scene.step()
        try await scene.render()
        // Wielokąt 16×16: pas 3 przy krawędziach, także przy rogu.
        scene.assertPixel([-10 + 6.8, 0], outline, "krawędź prawa")
        scene.assertPixel([-10, 6.8], outline, "krawędź górna")
        scene.assertPixel([-10 + 6.5, 6.5], outline, "róg")
        scene.assertPixel([-10 + 3, 0], fill, "wnętrze")
        scene.assertPixel([-10, 0], fill, "środek")
        // Koło: pas od promienia 4 do 7.
        scene.assertPixel([12 + 5.8, 0], outline, "pas koła")
        scene.assertPixel([12, -5.8], outline, "pas koła u dołu")
        scene.assertPixel([12 + 2.8, 0], fill, "wnętrze koła")
        scene.assertPixel([12 + 7.6, 0], black, "poza kołem")
    }

    // P-B-35: szerokość 0 oznacza brak obrysu mimo koloru obrysu.
    func testZeroOutlineWidthDrawsNoOutline() async throws {
        let scene = try makeScene([(materialA, RenderMaterial(color: RGBA(0, 0, 1),
            outline: RenderOutline(color: RGBA(1, 1, 0), width: 0)))])
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: materialA)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([7.5, 0], RGBA(0, 0, 1))
    }

    // P-B-39: renderer z rejestrem innego urządzenia zgłasza błąd przy tworzeniu.
    func testRendererWithRegistryOfAnotherDeviceThrowsOnCreation() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let foreign = AssetRegistry(device: device, deviceRegistryID: device.registryID &+ 1)
        XCTAssertThrowsError(try BubblePhysicsMetalRender(device: device, assets: foreign)) { error in
            XCTAssertEqual(error as? AssetError, .deviceMismatch)
        }
    }

    // P-B-39: świat i renderer z dwoma rejestrami tego samego urządzenia: klatka odrzucona, powód w diagnostyce.
    func testWorldAndRendererWithTwoRegistriesRejectTheFrame() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let worldRegistry = AssetRegistry(device: device), rendererRegistry = AssetRegistry(device: device)
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-50, -50], max: [50, 50]), fixedTimeStep: B.step),
            device: device, assets: worldRegistry)
        let renderer = try BubblePhysicsMetalRender(device: device, assets: rendererRegistry)
        let harness = try OffscreenRenderHarness(device: device)
        world.submit(try B.baseTransaction().add(B.bubble(1, at: .zero, radius: 4, filter: ghost, role: .static)))
        let command = try harness.makeCommandBuffer()
        let frame = await world.advance(by: B.step, commandBuffer: command) {
            try renderer.encode(world: world, viewport: RenderTestScene.viewport, commandBuffer: command,
                                renderPassDescriptor: harness.makePass())
        }
        XCTAssertEqual(frame.stepIndex, 0, "klatka odrzucona")
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertEqual(world.diagnostics.lastRejectionReason, .frameEncoding)
        XCTAssertNil(world.diagnostics.failureReason)
    }

    // P-B-39: ten sam rejestr w świecie i rendererze daje klatkę.
    func testWorldAndRendererSharingTheRegistryRenderTheFrame() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let registry = AssetRegistry(device: device)
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-50, -50], max: [50, 50]), fixedTimeStep: B.step),
            device: device, assets: registry)
        let renderer = try BubblePhysicsMetalRender(device: device, assets: registry)
        let harness = try OffscreenRenderHarness(device: device)
        world.submit(try B.baseTransaction()
            .updateRenderMaterial(materialA, material: RenderMaterial(color: RGBA(1, 0, 0)))
            .add(B.bubble(1, at: .zero, radius: 4, filter: ghost, role: .static, render: materialA)))
        let command = try harness.makeCommandBuffer()
        let frame = await world.advance(by: B.step, commandBuffer: command) {
            try renderer.encode(world: world, viewport: RenderTestScene.viewport, commandBuffer: command,
                                renderPassDescriptor: harness.makePass())
        }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        harness.assertPixel([0, 0], RenderTestScene.viewport, RGBA(1, 0, 0))
    }
}
