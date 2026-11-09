import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import CoreGraphics
import Metal
import XCTest

/// P-B-35 (tekstura z `CGImage` i z `MTLTexture`), P-B-36, P-B-37 (tryby tekstury na bańce), P-B-38 (obrót tekstury z bryłą),
/// P-B-41 (tło). Zasady mapowania, które sprawdzają testy:
/// - bryła: tekstura rozciągnięta na lokalny prostokąt otaczający bryły (wiersz 0 obrazu u góry), potem
///   `uv·uvScale + uvOffset` z powtarzaniem;
/// - bańka przyklejona: punkt konturu o kącie próbki θ ma punkt tekstury `0,5 + 0,5·(cos θ, −sin θ)`, więc tekstura leży
///   na kole o promieniu docelowym i podąża za konturem;
/// - bańka pod maską: punkt świata ma punkt tekstury `0,5 + (p − środek)/(2·promień docelowy)` (oś V w dół), a kontur przycina.
@MainActor
final class MaterialTextureRenderTests: XCTestCase {
    private typealias B = SceneBuilders
    private let ghost = RenderTestScene.ghost
    private let red = RGBA(1, 0, 0), green = RGBA(0, 1, 0), blue = RGBA(0, 0, 1), white = RGBA(1, 1, 1), black = RGBA(0, 0, 0)
    private let materialID = RenderMaterialID(rawValue: 10)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    /// 2×2: czerwony, zielony / niebieski, biały (wiersz po wierszu od góry).
    private func quadrantImage() throws -> CGImage {
        try OffscreenRenderHarness.image(width: 2, height: 2, pixels: [
            [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255]])
    }

    /// 128×128: tarcza niebieska w środku i czerwony pierścień od promienia 0,42 do brzegu (promień 0,5).
    private func bullseyeImage() throws -> CGImage {
        let size = 128
        var pixels: [[UInt8]] = []
        for row in 0..<size {
            for column in 0..<size {
                let x = (Float(column) + 0.5) / Float(size) - 0.5, y = (Float(row) + 0.5) / Float(size) - 0.5
                pixels.append((x * x + y * y).squareRoot() < 0.42 ? [0, 0, 255, 255] : [255, 0, 0, 255])
            }
        }
        return try OffscreenRenderHarness.image(width: size, height: size, pixels: pixels)
    }

    private func makeScene(texture: CGImage, uvOffset: SIMD2<Float> = .zero, uvScale: SIMD2<Float> = SIMD2(1, 1),
                           mapping: BubbleTextureMapping = .attached, region: WorldRectangle? = nil) throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), region: region)
        let registered = try scene.assets.register(texture)
        try scene.submitMaterials([(materialID, RenderMaterial(texture: registered, bubbleMapping: mapping,
                                                               uvOffset: uvOffset, uvScale: uvScale))])
        return scene
    }

    private func staticBody(_ value: UInt64, _ shape: RigidShape, rotation: Float = 0) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), shape: shape, position: .zero, rotation: rotation,
            motionRole: .static, physicsMaterialID: B.polygonMaterial, renderMaterialID: materialID, filter: ghost))
    }

    private func box(_ half: Float) throws -> RigidShape {
        .polygon(try PolygonGeometry(vertices: [[-half, -half], [half, -half], [half, half], [-half, half]]))
    }

    // P-B-35: tekstura z `CGImage` rozciągnięta na bryłę; ćwiartki tekstury w ćwiartkach bryły.
    func testTextureFromCGImageCoversPolygonQuadrants() async throws {
        let scene = try makeScene(texture: quadrantImage())
        scene.world.submit(try WorldTransaction().add(staticBody(1, box(8))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-4, 4], red, "lewa góra"); scene.assertPixel([4, 4], green, "prawa góra")
        scene.assertPixel([-4, -4], blue, "lewy dół"); scene.assertPixel([4, -4], white, "prawy dół")
    }

    // P-B-35: tekstura z gotowego `MTLTexture`; kolor mnoży teksturę.
    func testTextureFromMetalTextureIsMultipliedByColor() async throws {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(scene.device.makeTexture(descriptor: descriptor))
        let bytes: [UInt8] = [255, 255, 255, 255, 0, 255, 0, 255, 255, 255, 255, 255, 0, 255, 0, 255]
        texture.replace(region: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 8)
        let registered = try scene.assets.register(texture)
        try scene.submitMaterials([(materialID, RenderMaterial(texture: registered, color: RGBA(1, 0.5, 0.5)))])
        scene.world.submit(try WorldTransaction().add(staticBody(1, box(8))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-4, 4], RGBA(1, 0.5, 0.5), "biały texel razy kolor")
        scene.assertPixel([4, 4], RGBA(0, 0.5, 0), "zielony texel razy kolor")
    }

    // P-B-38: obrót bryły obraca teksturę; koło, kapsuła i wielokąt (obrót o 90° w lewo).
    func testTextureRotatesWithRigidBodies() async throws {
        let scene = try makeScene(texture: quadrantImage())
        scene.world.submit(try WorldTransaction().add(staticBody(1, box(8), rotation: .pi / 2)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-4, -4], red, "czerwony z lewej góry trafia w lewy dół")
        scene.assertPixel([-4, 4], green); scene.assertPixel([4, -4], blue); scene.assertPixel([4, 4], white)
    }

    func testTextureRotatesWithCircle() async throws {
        let scene = try makeScene(texture: quadrantImage())
        scene.world.submit(try WorldTransaction().add(staticBody(1, .circle(radius: 8), rotation: .pi / 2)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-4, -4], red); scene.assertPixel([-4, 4], green)
        scene.assertPixel([4, -4], blue); scene.assertPixel([4, 4], white)
    }

    func testTextureRotatesWithCapsule() async throws {
        let scene = try makeScene(texture: quadrantImage())
        // Kapsuła ma lokalny prostokąt 24×8, więc po obrocie o 90° stoi pionowo, a ćwiartki leżą w (±2, ±6).
        scene.world.submit(try WorldTransaction().add(staticBody(1, .capsule(halfLength: 8, radius: 4), rotation: .pi / 2)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-2, -6], red); scene.assertPixel([-2, 6], green)
        scene.assertPixel([2, -6], blue); scene.assertPixel([2, 6], white)
    }

    // P-B-38: skala UV powtarza teksturę (2×2 kafelki), przesunięcie UV przesuwa ją cyklicznie.
    func testUVScaleRepeatsAndUVOffsetShiftsTheTexture() async throws {
        let scaled = try makeScene(texture: quadrantImage(), uvScale: SIMD2(2, 2))
        scaled.world.submit(try WorldTransaction().add(staticBody(1, box(8))))
        await scaled.step()
        try await scaled.render()
        scaled.assertPixel([-6, 6], red); scaled.assertPixel([-2, 6], green)
        scaled.assertPixel([-6, 2], blue); scaled.assertPixel([-2, 2], white)
        scaled.assertPixel([2, 6], red, "drugi kafelek"); scaled.assertPixel([6, -6], white, "drugi kafelek")

        let shifted = try makeScene(texture: quadrantImage(), uvOffset: SIMD2(0.5, 0))
        shifted.world.submit(try WorldTransaction().add(staticBody(1, box(8))))
        await shifted.step()
        try await shifted.render()
        shifted.assertPixel([-4, 4], green, "przesunięcie o pół tekstury w poziomie"); shifted.assertPixel([4, 4], red)
        shifted.assertPixel([-4, -4], white); shifted.assertPixel([4, -4], blue)
    }

    // MARK: bańka zdeformowana ścianą

    /// Deformowalna bańka (promień 8) dociśnięta do statycznej ściany po prawej; po jednym kroku jej prawa strona jest spłaszczona.
    private func deformedBubbleScene(mapping: BubbleTextureMapping, texture: CGImage)
        async throws -> (scene: RenderTestScene, center: WorldPoint, contour: [WorldPoint]) {
        let scene = try makeScene(texture: texture, mapping: mapping)
        scene.world.submit(try WorldTransaction()
            .updatePhysicsMaterial(B.bubbleMaterial, material: PhysicsMaterial(kind: .bubble, deformability: 1))
            .add(B.box(10, at: [8, 0], half: [8, 30]))
            .add(B.bubble(1, at: [-4.8, 0], radius: 8, render: materialID)))
        let frame = await scene.step()
        let state = try XCTUnwrap(frame.objects[id(1)])
        let contour = try XCTUnwrap(scene.world.debugContourSnapshot()[id(1)])
        try await scene.render()
        return (scene, state.position, contour)
    }

    /// Punkt tuż wewnątrz konturu, w stronę środka.
    private func inside(_ contourPoint: WorldPoint, center: WorldPoint, by distance: Float = 0.3) -> WorldPoint {
        let toCenter = center - contourPoint
        return contourPoint + toCenter / (toCenter * toCenter).sum().squareRoot() * distance
    }

    /// Punkt konturu najbliższy środkowi (spłaszczony przez ścianę) i punkt najdalszy w lewo (nietknięty).
    private func flatAndRoundSides(_ contour: [WorldPoint], center: WorldPoint) throws -> (flat: WorldPoint, round: WorldPoint) {
        func radius(_ point: WorldPoint) -> Float { ((point - center) * (point - center)).sum().squareRoot() }
        let flat = try XCTUnwrap(contour.min { radius($0) < radius($1) })
        let round = try XCTUnwrap(contour.min { $0.x < $1.x })
        XCTAssertLessThan(radius(flat), 0.75 * 8, "warunek wstępny: strona ściany jest spłaszczona")
        XCTAssertGreaterThan(radius(round), 0.97 * 8, "warunek wstępny: lewa strona nie jest zdeformowana")
        return (flat, round)
    }

    // P-B-36: tryb przyklejony. Punkt tekstury zostaje przy punkcie konturu, więc pierścień na brzegu tekstury leży przy
    // konturze także tam, gdzie ściana go spłaszczyła.
    func testAttachedModeKeepsTexturePointAtTheContourPoint() async throws {
        let (scene, center, contour) = try await deformedBubbleScene(mapping: .attached, texture: bullseyeImage())
        let sides = try flatAndRoundSides(contour, center: center)
        scene.assertPixel(inside(sides.flat, center: center), red, "spłaszczona strona: rim tekstury przy konturze")
        scene.assertPixel(inside(sides.round, center: center), red, "okrągła strona: rim tekstury przy konturze")
        scene.assertPixel(center, blue, "środek tarczy")
    }

    // P-B-36: stała orientacja; ćwiartki tekstury leżą w ćwiartkach kierunku od środka bańki, także po deformacji.
    func testAttachedModeKeepsConstantOrientation() async throws {
        let (scene, center, contour) = try await deformedBubbleScene(mapping: .attached, texture: quadrantImage())
        for (direction, expected) in [(WorldPoint(-1, 1), red), (WorldPoint(1, 1), green),
                                      (WorldPoint(-1, -1), blue), (WorldPoint(1, -1), white)] {
            let point = try XCTUnwrap(contour.max { lhs, rhs in
                (lhs - center).normalizedDot(direction) < (rhs - center).normalizedDot(direction) })
            scene.assertPixel(inside(point, center: center, by: 0.5), expected, "kierunek \(direction)")
        }
    }

    // P-B-37: tryb pod maską. Tekstura to koło o promieniu docelowym, które się nie deformuje: przy spłaszczonym konturze
    // widać tarczę (niebieską), nie pierścień, a kontur przycina teksturę.
    func testMaskedModeDoesNotDeformTheTextureAndTheContourClipsIt() async throws {
        let (scene, center, contour) = try await deformedBubbleScene(mapping: .masked, texture: bullseyeImage())
        let sides = try flatAndRoundSides(contour, center: center)
        scene.assertPixel(inside(sides.flat, center: center), blue, "spłaszczona strona: tarcza dochodzi do konturu")
        scene.assertPixel(inside(sides.round, center: center), red, "okrągła strona: pierścień przy konturze")
        scene.assertPixel(center + [6.4, 0], black, "poza spłaszczonym konturem tekstura jest przycięta")
    }

    // P-B-37: tryb pod maską ma stałą orientację.
    func testMaskedModeKeepsConstantOrientation() async throws {
        let (scene, center, contour) = try await deformedBubbleScene(mapping: .masked, texture: quadrantImage())
        for (direction, expected) in [(WorldPoint(-1, 1), red), (WorldPoint(1, 1), green),
                                      (WorldPoint(-1, -1), blue), (WorldPoint(1, -1), white)] {
            let point = try XCTUnwrap(contour.max { lhs, rhs in
                (lhs - center).normalizedDot(direction) < (rhs - center).normalizedDot(direction) })
            scene.assertPixel(inside(point, center: center, by: 0.5), expected, "kierunek \(direction)")
        }
    }

    // P-B-41: tło rozciągnięte na region pod wszystkimi warstwami; po usunięciu znika.
    func testBackgroundStretchesOverRegionBelowAllLayersAndDisappearsWhenRemoved() async throws {
        let region = try WorldRectangle(min: [-20, -20], max: [20, 20])
        let scene = try makeScene(texture: quadrantImage(), region: region)
        let background = try scene.assets.register(quadrantImage())
        // Kamera szersza niż region: poza regionem zostaje tło okna renderu (czerń).
        let wide = try Viewport(center: .zero, size: [60, 60])
        scene.world.submit(try WorldTransaction()
            .updateRenderMaterial(RenderMaterialID(rawValue: 20), material: RenderMaterial(color: RGBA(1, 0, 1)))
            .setBackground(background)
            .add(B.bubble(1, at: .zero, radius: 4, filter: ghost, role: .static, render: RenderMaterialID(rawValue: 20), layer: -7)))
        await scene.step()
        try await scene.render(viewport: wide)
        scene.assertPixel([-10, 10], red, "lewa góra regionu", viewport: wide)
        scene.assertPixel([10, 10], green, "prawa góra regionu", viewport: wide)
        scene.assertPixel([-10, -10], blue, "lewy dół regionu", viewport: wide)
        scene.assertPixel([10, -10], white, "prawy dół regionu", viewport: wide)
        scene.assertPixel([0, 0], RGBA(1, 0, 1), "obiekt na warstwie −7 leży nad tłem", viewport: wide)
        scene.assertPixel([25, 0], black, "poza regionem", viewport: wide)

        scene.world.submit(try WorldTransaction().setBackground(nil))
        await scene.step()
        try await scene.render(viewport: wide)
        scene.assertPixel([-10, 10], black, "po usunięciu tła", viewport: wide)
        scene.assertPixel([10, -10], black, "po usunięciu tła", viewport: wide)
        scene.assertPixel([0, 0], RGBA(1, 0, 1), "obiekt zostaje", viewport: wide)
    }
}

private extension SIMD2 where Scalar == Float {
    /// Cosinus kąta między wektorem a kierunkiem (bez dzielenia przez zero dla wektora zerowego).
    func normalizedDot(_ other: SIMD2<Float>) -> Float {
        let length = (self * self).sum().squareRoot() * (other * other).sum().squareRoot()
        return length > 0 ? (self * other).sum() / length : -1
    }
}
