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

    /// Tarcza niebieska w środku i czerwony pierścień od promienia `rim` do brzegu (promień 0,5), `size`×`size` pikseli.
    private func bullseyeImage(size: Int = 128, rim: Float = 0.42) throws -> CGImage {
        var pixels: [[UInt8]] = []
        for row in 0..<size {
            for column in 0..<size {
                let x = (Float(column) + 0.5) / Float(size) - 0.5, y = (Float(row) + 0.5) / Float(size) - 0.5
                pixels.append((x * x + y * y).squareRoot() < rim ? [0, 0, 255, 255] : [255, 0, 0, 255])
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

    // P-B-35: tekstura z alfą przemnożoną (kontrakt rejestru). Teksel [64, 32, 0, 128] to prosty kolor (0,5; 0,25; 0) z alfą ≈ 0,5.
    private let underID = RenderMaterialID(rawValue: 20)
    private let texel = (premultiplied: SIMD3<Float>(64, 32, 0) / 255, alpha: Float(128) / 255)

    /// Niebieski spód (bryła 8×8) i nakładka 4×4 z jednotekselową teksturą o tym teksselu w podanym trybie mieszania.
    private func translucentScene(blend: RenderBlendMode, color: RGBA = RGBA(1, 1, 1)) async throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let registered = try scene.assets.register(OffscreenRenderHarness.image(width: 1, height: 1, pixels: [[64, 32, 0, 128]]))
        try scene.submitMaterials([(underID, RenderMaterial(color: blue)),
                                   (materialID, RenderMaterial(texture: registered, color: color, blend: blend))])
        scene.world.submit(try WorldTransaction()
            .add(B.box(1, at: .zero, half: [8, 8], filter: ghost, render: underID))
            .add(B.box(2, at: .zero, half: [4, 4], filter: ghost, render: materialID)))
        await scene.step()
        try await scene.render()
        return scene
    }

    func testTranslucentTexelInAlphaAndAdditiveModes() async throws {
        let (t, a) = (texel.premultiplied, texel.alpha)
        // Alfa: wynik = źródło + spód·(1 − alfa źródła), źródło = kolor·teksel (przemnożony)·alfa koloru.
        let alpha = try await translucentScene(blend: .alpha)
        alpha.assertPixel([0, 0], RGBA(t.x, t.y, t.z + (1 - a)), "alfa: teksel nad spodem")
        alpha.assertPixel([6, 0], blue, "alfa: poza nakładką spód")
        let halfColor = try await translucentScene(blend: .alpha, color: RGBA(1, 1, 1, 0.5))
        halfColor.assertPixel([0, 0], RGBA(t.x * 0.5, t.y * 0.5, t.z * 0.5 + (1 - a * 0.5)), "alfa: alfa koloru razy alfa teksela")
        // Addytywny: wynik = spód + źródło (przycięte do 1).
        let additive = try await translucentScene(blend: .additive)
        additive.assertPixel([0, 0], RGBA(t.x, t.y, 1), "addytywny: spód plus teksel")
        additive.assertPixel([6, 0], blue, "addytywny: poza nakładką spód")
    }

    // Tryb nieprzezroczysty dzieli teksel przez jego alfę (odzyskuje kolor prosty) i ignoruje alfę.
    func testOpaqueModeUnpremultipliesTexelWithAlphaBelowOne() async throws {
        let opaque = try await translucentScene(blend: .opaque)
        opaque.assertPixel([0, 0], RGBA(0.5, 0.25, 0), "kolor prosty teksela, spód niewidoczny")
        let tinted = try await translucentScene(blend: .opaque, color: RGBA(1, 0.5, 1, 0.2))
        tinted.assertPixel([0, 0], RGBA(0.5, 0.125, 0), "kolor mnoży kolor prosty, alfa koloru ignorowana")
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

    /// Granica tarcza/pierścień (od środka bańki do punktu konturu) w pikselach: gdzie ją widać i gdzie powinna leżeć.
    /// Punkt tekstury leży przy punkcie konturu, więc granica na promieniu `rim` tekstury leży w ułamku `2·rim` drogi od
    /// środka do konturu, czyli `(1 − 2·rim)·|kontur − środek|` pikseli od konturu.
    private func rimBoundary(_ scene: RenderTestScene, contourPoint: WorldPoint, center: WorldPoint, rim: Float) throws
        -> (measured: Float, expected: Float) {
        let size = WorldPoint(Float(scene.harness.size), Float(scene.harness.size))
        let start = try RenderTestScene.viewport.screenPoint(for: center, in: size)
        let end = try RenderTestScene.viewport.screenPoint(for: contourPoint, in: size)
        let length = ((end - start) * (end - start)).sum().squareRoot()
        let direction = (end - start) / length
        var distance: Float = 0
        while distance < length + 2 {
            let point = start + direction * distance
            let pixel = scene.harness.pixel(x: Int(point.x.rounded(.down)), y: Int(point.y.rounded(.down)))
            if pixel[0] > 128 { break }   // pierwszy nie niebieski piksel od środka
            distance += 0.05
        }
        return (length - distance, (1 - 2 * rim) * length)
    }

    private func assertRimAtTheContour(_ scene: RenderTestScene, center: WorldPoint, contour: [WorldPoint], rim: Float,
                                       _ message: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let sides = try flatAndRoundSides(contour, center: center)
        let top = try XCTUnwrap(contour.max { $0.y < $1.y })
        for (name, point) in [("spłaszczona strona", sides.flat), ("okrągła strona", sides.round), ("góra", top)] {
            let boundary = try rimBoundary(scene, contourPoint: point, center: center, rim: rim)
            XCTAssertEqual(boundary.measured, boundary.expected, accuracy: 1.0,
                "\(message), \(name): granica pierścienia \(boundary.measured) px od konturu, oczekiwano \(boundary.expected) px",
                file: file, line: line)
        }
    }

    // P-B-36: tryb przyklejony. Punkt tekstury zostaje przy punkcie konturu, więc granica pierścienia leży przy konturze
    // dokładnie tam, gdzie wynika z mapowania (do 1 px), także gdzie ściana spłaszczyła kontur, a po ruchu bańki i kolejnym
    // renderze nadal.
    func testAttachedModeKeepsTexturePointAtTheContourPoint() async throws {
        let rim: Float = 0.44
        let (scene, center, contour) = try await deformedBubbleScene(mapping: .attached, texture: bullseyeImage(size: 256, rim: rim))
        let sides = try flatAndRoundSides(contour, center: center)
        scene.assertPixel(inside(sides.flat, center: center), red, "spłaszczona strona: rim tekstury przy konturze")
        scene.assertPixel(inside(sides.round, center: center), red, "okrągła strona: rim tekstury przy konturze")
        scene.assertPixel(center, blue, "środek tarczy")
        try assertRimAtTheContour(scene, center: center, contour: contour, rim: rim, "po pierwszym kroku")

        // Ruch wymuszony: zamiana bańki na taką o innym położeniu i prędkości, potem kolejne kroki i render.
        scene.world.submit(try WorldTransaction().replace(id(1), with: B.bubble(1, at: [-3.6, 3], radius: 8,
            velocity: [4, 12], render: materialID)))
        await scene.step()
        let frame = await scene.step()
        let moved = try XCTUnwrap(frame.objects[id(1)]).position
        let movedContour = try XCTUnwrap(scene.world.debugContourSnapshot()[id(1)])
        XCTAssertGreaterThan(moved.y, center.y + 0.1, "warunek wstępny: bańka się przesunęła")
        try await scene.render()
        try assertRimAtTheContour(scene, center: moved, contour: movedContour, rim: rim, "po ruchu bańki")
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
        // Punkt sondy musi leżeć poza konturem i na lewo od białej ściany (x ≥ 0), inaczej czerń nie dowodzi przycięcia.
        let probe = center + [6.4, 0]
        XCTAssertLessThan(probe.x, 0, "warunek wstępny: sonda leży na lewo od ściany (x = 0)")
        XCTAssertFalse(contains(contour, probe), "warunek wstępny: sonda leży poza spłaszczonym konturem")
        XCTAssertTrue(contains(contour, inside(sides.flat, center: center)), "warunek wstępny: kontrola wnętrza konturu")
        scene.assertPixel(probe, black, "poza spłaszczonym konturem tekstura jest przycięta")
    }

    /// Czy punkt leży wewnątrz wielokąta konturu (reguła parzystości).
    private func contains(_ polygon: [WorldPoint], _ point: WorldPoint) -> Bool {
        var result = false
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
        }
        return result
    }

    // G3-AC4: przesunięcie i skala UV dotyczą brył; na bańce (oba tryby) są ignorowane, więc tekstura zostaje kołem o promieniu
    // docelowym, bez powtarzania. Ćwiartki leżą w ćwiartkach bańki także przy skali 2 i przesunięciu.
    func testUVOffsetAndScaleAreIgnoredOnBubbles() async throws {
        for mapping in [BubbleTextureMapping.attached, .masked] {
            let scene = try makeScene(texture: quadrantImage(), uvOffset: SIMD2(0.3, 0.2), uvScale: SIMD2(2, 2), mapping: mapping)
            scene.world.submit(try WorldTransaction()
                .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: materialID)))
            await scene.step()
            try await scene.render()
            scene.assertPixel([-3, 3], red, "\(mapping) lewa góra"); scene.assertPixel([3, 3], green, "\(mapping) prawa góra")
            scene.assertPixel([-3, -3], blue, "\(mapping) lewy dół"); scene.assertPixel([3, -3], white, "\(mapping) prawy dół")
        }
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
