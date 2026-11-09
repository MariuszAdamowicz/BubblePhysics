import BubblePhysics
import BubblePhysicsAssets
import CoreGraphics
import Metal
import XCTest

/// P-B-43 … P-B-48: naklejki. Zasady, które sprawdzają testy:
/// - kotwica w środku obiektu (bańka: środek, bryła: początek układu lokalnego), naklejka tekstowa wyśrodkowana w kotwicy;
/// - promień odniesienia R: bańka to jej promień docelowy (stały, niezależny od chwilowej deformacji; efektywny promień to
///   najmniejsza odległość konturu od środka, więc kontur nigdy nie przecinałby koła o tym promieniu), bryła promień okręgu
///   opisanego na kształcie wokół kotwicy;
/// - skala 1 daje linię tekstu o wysokości R, a obraz w kwadracie o boku 2R (z zachowaniem proporcji fragmentu);
/// - 1× w atlasie SDF to wysokość linii 32 teksle, więc przy R = 32 px jeden teksel to jeden piksel;
/// - naklejka jest zawsze przycinana do koła R, na bańce także do jej konturu, ale sama się nie deformuje;
/// - na bryle naklejka obraca się z nią, na bańce ma stałą orientację;
/// - w warstwie kolejność to bańki, naklejki baniek, bryły, naklejki brył.
@MainActor
final class DecalRenderTests: XCTestCase {
    private typealias B = SceneBuilders
    private let ghost = RenderTestScene.ghost
    private let red = RGBA(1, 0, 0), green = RGBA(0, 1, 0), blue = RGBA(0, 0, 1), white = RGBA(1, 1, 1), black = RGBA(0, 0, 0)
    private let blackID = RenderMaterialID(rawValue: 10), redID = RenderMaterialID(rawValue: 11)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func makeScene(region: WorldRectangle? = nil) throws -> RenderTestScene {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), region: region)
        try scene.submitMaterials([(blackID, RenderMaterial(color: black)), (redID, RenderMaterial(color: red))])
        return scene
    }

    /// 2×2: czerwony, zielony / niebieski, biały (wiersz po wierszu od góry).
    private func quadrantImage() throws -> CGImage {
        try OffscreenRenderHarness.image(width: 2, height: 2, pixels: [
            [255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 255]])
    }

    private func solidImage(_ color: [UInt8]) throws -> CGImage {
        try OffscreenRenderHarness.image(width: 1, height: 1, pixels: [color])
    }

    /// Tarcza niebieska w środku i czerwony pierścień od promienia `rim` do brzegu (promień 0,5).
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

    // MARK: P-B-43 — tekst SDF: glif 1× ma 32 px, krawędź ostra w każdej skali

    /// Pełny kwadrat ■ z czcionki systemowej: stały, szeroki kształt, na którym da się zmierzyć krawędź w skali 0,25×.
    private let blockFont = "Menlo-Regular", block: Character = "\u{25A0}"

    /// Przecięcia profilu z poziomem `level`; pozycje w pikselach (środek piksela k leży w k + 0,5), interpolacja liniowa.
    private func crossings(_ profile: [Float], level: Float = 0.5) -> [Float] {
        var result: [Float] = []
        for index in 0..<(profile.count - 1) where (profile[index] < level) != (profile[index + 1] < level) {
            result.append(Float(index) + 0.5 + (level - profile[index]) / (profile[index + 1] - profile[index]))
        }
        return result
    }

    /// Kanał czerwony jako alfa naklejki (biała naklejka na czarnym tle), wiersz albo kolumna.
    private func profile(_ harness: OffscreenRenderHarness, row: Int? = nil, column: Int? = nil) -> [Float] {
        (0..<harness.size).map { index in
            Float(harness.pixel(x: column ?? index, y: row ?? index)[0]) / 255
        }
    }

    /// Szerokość krawędzi 10%→90% z funkcji rozmycia krawędzi (ESF): ta sama krawędź prosta, widziana przy wielu
    /// podpikselowych przesunięciach kamery, daje gęsty profil `alfa(u)` z `u` w pikselach od krawędzi. Próbki w środkach
    /// pikseli pojedynczego obrazu nie pozwalają zmierzyć rampy węższej niż ok. 1,6 px (zależnie od położenia krawędzi),
    /// a po złożeniu przesunięć pomiar ma rozdzielczość ułamka piksela.
    private func edgeTransitionWidth(_ profiles: [(shift: Float, samples: [Float])], edge: Float) -> Float? {
        var points: [(u: Float, alpha: Float)] = []
        for (shift, samples) in profiles {
            for (index, alpha) in samples.enumerated() {
                let u = Float(index) + 0.5 - (edge + shift)
                if abs(u) <= 3 { points.append((u, alpha)) }
            }
        }
        points.sort { $0.u < $1.u }
        // Położenie poziomu: pierwsze przecięcie gęstego, posortowanego profilu, z interpolacją liniową.
        func position(_ level: Float) -> Float? {
            for index in 0..<max(points.count - 1, 0) {
                let (a, b) = (points[index], points[index + 1])
                if a.alpha != b.alpha, (a.alpha - level) * (b.alpha - level) <= 0 {
                    return a.u + (level - a.alpha) / (b.alpha - a.alpha) * (b.u - a.u)
                }
            }
            return nil
        }
        guard let low = position(0.1), let high = position(0.9) else { return nil }
        return abs(high - low)
    }

    /// Szerokość i wysokość ■ w tekselach atlasu: przecięcia pola odległości z 0,5 na środkowym wierszu i kolumnie komórki.
    private func glyphSizeInTexels(_ atlas: GlyphAtlas, _ metrics: GlyphMetrics) -> SIMD2<Float> {
        let side = atlas.texture.width
        var bytes = [UInt8](repeating: 0, count: side * atlas.texture.height)
        atlas.texture.getBytes(&bytes, bytesPerRow: side, from: MTLRegionMake2D(0, 0, side, atlas.texture.height), mipmapLevel: 0)
        func value(_ x: Int, _ y: Int) -> Float { Float(bytes[y * side + x]) / 255 }
        let x0 = Int(metrics.origin.x), y0 = Int(metrics.origin.y)
        let midX = x0 + Int(metrics.size.x) / 2, midY = y0 + Int(metrics.size.y) / 2
        let row = crossings((0..<Int(metrics.size.x)).map { value(x0 + $0, midY) })
        let column = crossings((0..<Int(metrics.size.y)).map { value(midX, y0 + $0) })
        XCTAssertEqual(row.count, 2, "środkowy wiersz przecina kontur ■ dwa razy")
        XCTAssertEqual(column.count, 2, "środkowa kolumna przecina kontur ■ dwa razy")
        return SIMD2((row.last ?? 0) - (row.first ?? 0), (column.last ?? 0) - (column.first ?? 0))
    }

    /// Render ■ białym kolorem na czarnej bańce o promieniu 5 jednostek; `magnification` to piksele na teksel atlasu
    /// (kamera: 6,4 · m pikseli na jednostkę, więc R = 32 · m px, a linia tekstu ma 32 · m px).
    private func makeBlockScene() async throws -> (scene: RenderTestScene, atlas: GlyphAtlas, metrics: GlyphMetrics) {
        let scene = try makeScene()
        let font = try scene.assets.register(font: blockFont, characters: String(block))
        let atlas = try XCTUnwrap(scene.assets.atlas(for: .font(font)))
        let metrics = try XCTUnwrap(atlas.glyphs[block])
        scene.world.submit(try WorldTransaction().add(B.bubble(1, at: .zero, radius: 5, filter: ghost, role: .static, render: blackID,
            decal: .text(String(block), source: .font(font)))))
        await scene.step()
        return (scene, atlas, metrics)
    }

    /// Render ■ białym kolorem na czarnej bańce o promieniu 5 jednostek; `magnification` to piksele na teksel atlasu
    /// (kamera: 6,4 · m pikseli na jednostkę, więc R = 32 · m px, a linia tekstu ma 32 · m px). `shift` przesuwa obraz
    /// o tyle pikseli w prawo i w dół.
    private func renderBlock(_ scene: RenderTestScene, magnification m: Float, shift: SIMD2<Float> = .zero) async throws {
        let pixelsPerUnit = 6.4 * m
        // Kamera przesunięta w lewo i w górę przesuwa obraz w prawo i w dół.
        let center = WorldPoint(-shift.x, shift.y) / pixelsPerUnit
        try await scene.render(viewport: Viewport(center: center, size: [40 / m, 40 / m]))
    }

    func testGlyphAtOneTimesHasThirtyTwoPixelLineHeightAndSharpEdgesAtEveryScale() async throws {
        let (scene, atlas, metrics) = try await makeBlockScene()
        XCTAssertEqual(atlas.lineHeight, 32, accuracy: 1e-3)
        let harness = scene.harness
        for magnification in [Float(0.25), 1, 4] {
            try await renderBlock(scene, magnification: magnification)
            let column = harness.size / 2
            let vertical = crossings(profile(harness, column: column))
            XCTAssertEqual(vertical.count, 2, "\(magnification)×: ■ na środkowej kolumnie")
            guard let top = vertical.first, let bottom = vertical.last else { continue }
            let middle = Int(((top + bottom) / 2).rounded(.down))
            let horizontal = crossings(profile(harness, row: middle))
            XCTAssertEqual(horizontal.count, 2, "\(magnification)×: ■ na środkowym wierszu")
            guard let left = horizontal.first, let right = horizontal.last else { continue }
            let expected = glyphSizeInTexels(atlas, metrics) * magnification
            let tolerance = 1 + 0.5 * magnification
            XCTAssertEqual(right - left, expected.x, accuracy: tolerance, "\(magnification)×: szerokość glifu w pikselach")
            XCTAssertEqual(bottom - top, expected.y, accuracy: tolerance, "\(magnification)×: wysokość glifu w pikselach")
            if magnification == 1 {
                XCTAssertEqual(right - left, glyphSizeInTexels(atlas, metrics).x, accuracy: 1.5, "1× to jeden teksel na piksel")
            }
            // Funkcja rozmycia krawędzi z 16 podpikselowych przesunięć w poziomie (krawędzie pionowe) i w pionie (poziome).
            var horizontalProfiles: [(shift: Float, samples: [Float])] = [], verticalProfiles = horizontalProfiles
            for step in 0..<16 {
                let offset = Float(step) / 16
                try await renderBlock(scene, magnification: magnification, shift: [offset, 0])
                horizontalProfiles.append((offset, profile(harness, row: middle)))
                try await renderBlock(scene, magnification: magnification, shift: [0, offset])
                verticalProfiles.append((offset, profile(harness, column: column)))
            }
            for (name, edge, profiles) in [("lewa", left, horizontalProfiles), ("prawa", right, horizontalProfiles),
                                           ("górna", top, verticalProfiles), ("dolna", bottom, verticalProfiles)] {
                let width = try XCTUnwrap(edgeTransitionWidth(profiles, edge: edge), "\(magnification)×: krawędź \(name)")
                XCTAssertLessThanOrEqual(width, 1.5, "\(magnification)×: krawędź \(name), alfa 10%→90%")
            }
        }
    }

    // MARK: P-B-44 — gotowy atlas

    /// Atlas 16×16 teksli: „A” w lewej połowie (górna połowa pełna, dolna pusta), „B” w prawej (jednolite pół krycia).
    /// Wysokość linii 16 (ascent 12, descent 4), przesuw 8, więc przy R = 8 jeden teksel to pół jednostki świata.
    private func readyAtlas(_ scene: RenderTestScene) throws -> GlyphAtlasID {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: 16, height: 16, mipmapped: false)
        descriptor.usage = .shaderRead
        let texture = try XCTUnwrap(scene.device.makeTexture(descriptor: descriptor))
        var bytes = [UInt8](repeating: 0, count: 256)
        for row in 0..<16 { for column in 0..<16 {
            bytes[row * 16 + column] = column < 8 ? (row < 8 ? 255 : 0) : 128
        } }
        texture.replace(region: MTLRegionMake2D(0, 0, 16, 16), mipmapLevel: 0, withBytes: bytes, bytesPerRow: 16)
        return try scene.assets.register(glyphAtlas: GlyphAtlas(texture: texture, glyphs: [
            "A": GlyphMetrics(origin: [0, 0], size: [8, 16], offset: [0, -4], advance: 8),
            "B": GlyphMetrics(origin: [8, 0], size: [8, 16], offset: [0, -4], advance: 8)],
            ascent: 12, descent: 4, isSignedDistanceField: false))
    }

    func testTextFromAReadyAtlasDrawsItsGlyphsInTheTintColor() async throws {
        let scene = try makeScene()
        let atlas = try readyAtlas(scene)
        let tint = RGBA(1, 0.5, 0)
        scene.world.submit(try WorldTransaction().add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: blackID,
            decal: .text("AB", source: .atlas(atlas), color: tint))))
        await scene.step()
        try await scene.render()
        // „A” zajmuje x ∈ [−4, 0], „B” x ∈ [0, 4], oba y ∈ [−4, 4] (tekst wyśrodkowany w kotwicy).
        scene.assertPixel([-2, 2], tint, "A: pełna górna połowa w kolorze naklejki")
        scene.assertPixel([-2, -2], black, "A: dolna połowa pusta (wiersz 0 atlasu u góry)")
        scene.assertPixel([2, 2], RGBA(128.0 / 255, 64.0 / 255, 0), "B: pół krycia razem z kolorem naklejki")
        scene.assertPixel([2, -2], RGBA(128.0 / 255, 64.0 / 255, 0), "B: pół krycia także na dole")
        scene.assertPixel([-6, 0], black, "poza czworokątem glifu")
        scene.assertPixel([0, 6], black, "nad linią tekstu")
    }

    // MARK: P-B-45 — obraz

    func testImageDecalShowsTheChosenRegionOfTheTexture() async throws {
        let scene = try makeScene()
        let texture = try scene.assets.register(quadrantImage())
        // Prawa górna ćwiartka (zielona) wypełnia koło odniesienia; poza kołem (R = 8) nic.
        scene.world.submit(try WorldTransaction().add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: blackID,
            decal: .image(texture, region: TextureRegion(min: [0.5, 0], max: [1, 0.5])))))
        await scene.step()
        try await scene.render()
        for point: WorldPoint in [[-4, 4], [4, 4], [-4, -4], [4, -4], [0, 0]] { scene.assertPixel(point, green, "\(point) w kole") }
        scene.assertPixel([6.5, 6.5], black, "poza kołem odniesienia (odległość 9,2 > 8)")
    }

    func testImageDecalKeepsTheAspectOfTheRegionAndCentersItOnTheAnchor() async throws {
        let scene = try makeScene()
        let texture = try scene.assets.register(quadrantImage())
        // Lewa połowa tekstury (czerwony nad niebieskim) ma proporcje 1:2, więc zajmuje x ∈ [−4, 4], y ∈ [−8, 8].
        scene.world.submit(try WorldTransaction().add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: blackID,
            decal: .image(texture, region: TextureRegion(min: [0, 0], max: [0.5, 1])))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 4], red, "górna połowa"); scene.assertPixel([0, -4], blue, "dolna połowa")
        scene.assertPixel([-3, 3], red); scene.assertPixel([3, -3], blue)
        scene.assertPixel([5, 3], black, "poza fragmentem (proporcje zachowane)"); scene.assertPixel([-5, -3], black)
    }

    // MARK: P-B-46 — kotwica, obrót, przycięcie

    /// Deformowalna bańka (promień 8) dociśnięta do statycznej ściany po prawej; po jednym kroku jej prawa strona jest spłaszczona.
    private func deformedBubbleScene(image: CGImage, scale: Float = 1) async throws
        -> (scene: RenderTestScene, texture: TextureID, center: WorldPoint, effectiveRadius: Float, contour: [WorldPoint]) {
        let scene = try makeScene()
        let texture = try scene.assets.register(image)
        scene.world.submit(try WorldTransaction()
            .updatePhysicsMaterial(B.bubbleMaterial, material: PhysicsMaterial(kind: .bubble, deformability: 1))
            .add(B.box(10, at: [8, 0], half: [8, 30], render: blackID))
            .add(B.bubble(1, at: [-4.8, 0], radius: 8, render: blackID, decal: .image(texture, scale: scale))))
        let frame = await scene.step()
        let state = try XCTUnwrap(frame.objects[id(1)])
        guard case .bubble(let effectiveRadius) = state.kind else { throw XCTSkip("to nie bańka") }
        let contour = try XCTUnwrap(scene.world.debugContourSnapshot()[id(1)])
        try await scene.render()
        return (scene, texture, state.position, effectiveRadius, contour)
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

    private func unit(_ vector: WorldPoint) -> WorldPoint { vector / (vector * vector).sum().squareRoot() }

    /// Odległość konturu od środka w danym kierunku (kontur jest gwiaździsty względem środka bańki): bisekcja po `contains`.
    private func contourRadius(_ contour: [WorldPoint], center: WorldPoint, direction: WorldPoint) -> Float {
        var low: Float = 0, high: Float = 40
        for _ in 0..<40 {
            let middle = (low + high) / 2
            if contains(contour, center + direction * middle) { low = middle } else { high = middle }
        }
        return low
    }

    /// G5-AC4: promień odniesienia bańki to jej promień docelowy (tu 8), stały mimo deformacji. Naklejka jest przycięta do koła
    /// o tym promieniu i do zdeformowanego konturu: tam, gdzie kontur sięga poza promień efektywny, naklejka go wypełnia,
    /// a za wgnieceniem jej nie ma. Sama się nie deformuje: tarcza (0,84 R) i pierścień (do R) leżą na tych samych promieniach.
    func testDecalOnADeformedBubbleIsClippedToTheTargetRadiusCircleAndTheDentedContour() async throws {
        let target: Float = 8
        let (scene, _, center, effective, contour) = try await deformedBubbleScene(image: bullseyeImage())
        XCTAssertLessThan(effective, 0.75 * target, "warunek wstępny: bańka jest zdeformowana, promień efektywny mniejszy od docelowego")
        scene.assertPixel(center, blue, "środek")
        var filledBeyondEffective = 0, cutByDent = 0, cutByCircle = 0
        for step in 0..<24 {
            let angle = Float(step) / 24 * 2 * .pi
            let direction = WorldPoint(cos(angle), sin(angle))
            let rim = contourRadius(contour, center: center, direction: direction)
            XCTAssertGreaterThanOrEqual(rim, effective - 0.05, "promień efektywny to najmniejsza odległość konturu od środka")
            // Wewnątrz konturu i koła R: naklejka jest, na tych samych promieniach co bez deformacji.
            let inside = min(rim, target) - 0.5
            if inside > 0.84 * target + 0.3 {
                scene.assertPixel(center + direction * inside, red, "kąt \(step * 15)°: pierścień przy brzegu maski")
            }
            let probeDisc = min(inside, 0.84 * target - 0.4)
            scene.assertPixel(center + direction * probeDisc, blue, "kąt \(step * 15)°: tarcza")
            if inside > 1.1 * effective { filledBeyondEffective += 1 }
            // Za konturem (wgniecenie) naklejki nie ma, choć leży jeszcze w kole R.
            if rim + 0.5 < target - 0.3 {
                scene.assertPixel(center + direction * (rim + 0.5), black, "kąt \(step * 15)°: za wgnieceniem konturu")
                cutByDent += 1
            }
            // Za kołem R naklejki nie ma, choć kontur sięga dalej.
            if rim > target + 0.7 {
                scene.assertPixel(center + direction * (target + 0.5), black, "kąt \(step * 15)°: poza kołem docelowym")
                cutByCircle += 1
            }
        }
        XCTAssertGreaterThan(filledBeyondEffective, 0, "warunek wstępny: są kierunki, w których kontur sięga poza koło efektywne")
        XCTAssertGreaterThan(cutByDent, 0, "warunek wstępny: są kierunki, w których wgniecenie wchodzi w koło docelowe")
        _ = cutByCircle
    }

    /// Najdalszy punkt białej naklejki od środka w danym kierunku (krok 0,05 jednostki).
    private func whiteExtent(_ scene: RenderTestScene, center: WorldPoint, direction: WorldPoint) -> Float {
        var extent: Float = 0
        while extent < 12 {
            let next = extent + 0.05
            let pixel = scene.harness.pixel(at: center + direction * next, in: RenderTestScene.viewport)
            guard pixel[0] > 200, pixel[1] > 200, pixel[2] > 200 else { break }
            extent = next
        }
        return extent
    }

    /// G5-AC4: rozmiar naklejki zależy od promienia docelowego, nie od chwilowej deformacji: kwadrat o połowie boku 0,35 R ma
    /// na zdeformowanej bańce te same wymiary co na tej samej bańce bez deformacji.
    func testDecalOnADeformedBubbleHasTheSameSizeAsOnTheSameBubbleUndeformed() async throws {
        let target: Float = 8, half = 0.35 * target
        let solid = try solidImage([255, 255, 255, 255])
        let (deformed, _, center, effective, _) = try await deformedBubbleScene(image: solid, scale: 0.35)
        XCTAssertLessThan(effective, 0.75 * target, "warunek wstępny: bańka jest zdeformowana")
        XCTAssertGreaterThan(half, 0.4 * effective, "warunek wstępny: kwadrat jest zauważalnie większy niż przy skali względem efektywnego")
        let flat = try makeScene()
        let flatImage = try flat.assets.register(solid)
        flat.world.submit(try WorldTransaction().add(B.bubble(1, at: center, radius: target, filter: ghost, role: .static,
                                                               render: blackID, decal: .image(flatImage, scale: 0.35))))
        await flat.step()
        try await flat.render()
        for (name, direction) in [("w górę", WorldPoint(0, 1)), ("w dół", WorldPoint(0, -1)), ("w lewo", WorldPoint(-1, 0))] {
            let undeformed = whiteExtent(flat, center: center, direction: direction)
            XCTAssertEqual(undeformed, half, accuracy: 0.25, "bez deformacji \(name)")
            XCTAssertEqual(whiteExtent(deformed, center: center, direction: direction), undeformed, accuracy: 0.25, "\(name)")
        }
    }

    func testDecalOnABubbleKeepsConstantOrientationAfterDeformationAndMovement() async throws {
        let (rendered, quadrants, center, effective, _) = try await deformedBubbleScene(image: quadrantImage())
        let offset = 0.35 * effective
        for (direction, expected) in [(WorldPoint(-1, 1), red), (WorldPoint(1, 1), green),
                                      (WorldPoint(-1, -1), blue), (WorldPoint(1, -1), white)] {
            rendered.assertPixel(center + direction * offset, expected, "kierunek \(direction)")
        }
        // Kotwica w środku: po ruchu środek naklejki idzie za bańką, a orientacja zostaje.
        rendered.world.submit(try WorldTransaction().replace(id(1), with: B.bubble(1, at: [-3.6, 3], radius: 8,
            velocity: [4, 12], render: blackID, decal: .image(quadrants))))
        await rendered.step()
        let frame = await rendered.step()
        let moved = try XCTUnwrap(frame.objects[id(1)]).position
        XCTAssertGreaterThan(moved.y, center.y + 0.1, "warunek wstępny: bańka się przesunęła")
        try await rendered.render()
        rendered.assertPixel(moved + [-2, 2], red); rendered.assertPixel(moved + [2, 2], green)
        rendered.assertPixel(moved + [-2, -2], blue); rendered.assertPixel(moved + [2, -2], white)
    }

    func testDecalOnARotatedBodyRotatesWithIt() async throws {
        let scene = try makeScene()
        let quadrants = try scene.assets.register(quadrantImage())
        // Promień odniesienia bryły to promień okręgu opisanego: √(8² + 8²) ≈ 11,3, więc kwadrat naklejki ma bok 22,6.
        scene.world.submit(try WorldTransaction().add(B.box(1, at: .zero, half: [8, 8], filter: ghost, render: blackID,
            rotation: .pi / 2, decal: .image(quadrants))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-4, -4], red, "czerwony z lewej góry trafia w lewy dół"); scene.assertPixel([-4, 4], green)
        scene.assertPixel([4, -4], blue); scene.assertPixel([4, 4], white)

        let upright = try makeScene()
        let uprightImage = try upright.assets.register(quadrantImage())
        upright.world.submit(try WorldTransaction().add(B.box(1, at: .zero, half: [8, 8], filter: ghost, render: blackID,
            decal: .image(uprightImage))))
        await upright.step()
        try await upright.render()
        upright.assertPixel([-4, 4], red, "bez obrotu ćwiartki leżą jak w obrazie"); upright.assertPixel([4, -4], white)
    }

    func testBodyDecalIsDrawnInAWorldWithoutBubbles() async throws {
        let scene = try makeScene()
        let green = try scene.assets.register(solidImage([0, 255, 0, 255]))
        scene.world.submit(try WorldTransaction().add(B.box(1, at: .zero, half: [4, 4], filter: ghost, render: blackID,
                                                            decal: .image(green))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], RGBA(0, 1, 0), "naklejka bryły, gdy w świecie nie ma żadnej bańki")
    }

    func testDecalIsAnchoredAtTheObjectOriginOnACapsuleToo() async throws {
        let scene = try makeScene()
        let solid = try scene.assets.register(solidImage([255, 255, 255, 255]))
        // Kapsuła (półdługość 8, promień 3) ma promień okręgu opisanego 11 wokół kotwicy w jej środku, więc naklejka sięga
        // poza kształt (do okręgu), ale nie dalej.
        scene.world.submit(try WorldTransaction().add(B.capsule(1, at: [3, 0], halfLength: 8, radius: 3,
            role: .static, filter: ghost, render: blackID, decal: .image(solid, scale: 3))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([3, 5], white, "nad kapsułą, w kole odniesienia (odległość od kotwicy 5 < 11)")
        scene.assertPixel([3, 12], black, "poza kołem odniesienia (12 > 11)")
        scene.assertPixel([-6, 0], white, "w kole po lewej stronie kotwicy (odległość 9 < 11)")
        scene.assertPixel([-9, 0], black, "poza kołem (12 > 11)")
    }

    func testDecalWithScaleAboveOneIsStillClippedToTheReferenceCircle() async throws {
        let scene = try makeScene()
        let solid = try scene.assets.register(solidImage([255, 255, 255, 255]))
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-10, 0], radius: 6, filter: ghost, role: .static, render: blackID, decal: .image(solid, scale: 3)))
            .add(B.box(2, at: [10, 0], half: [4, 4], filter: ghost, render: blackID, decal: .image(solid, scale: 4))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-10, 0], white, "bańka: środek"); scene.assertPixel([-5, 0], white, "bańka: w kole (odległość 5 < 6)")
        scene.assertPixel([-17.2, 0], black, "bańka: poza kołem R = 6 mimo kwadratu o boku 36")
        // Bryła 8×8: promień opisany √32 ≈ 5,66, kwadrat naklejki o boku 45 przycięty do koła.
        scene.assertPixel([14.5, 0], white, "bryła: w kole poza kształtem (odległość 4,5 < 5,66)")
        scene.assertPixel([17, 0], black, "bryła: poza kołem (7 > 5,66)")
        scene.assertPixel([10, 5.2], white, "bryła: w kole nad kształtem (5,2 < 5,66)")
        scene.assertPixel([10, 6.5], black, "bryła: poza kołem")
    }

    // MARK: P-B-47 — kolejność w warstwie

    func testRigidBodyInTheSameLayerCoversABubbleTogetherWithItsDecal() async throws {
        let scene = try makeScene()
        let solid = try scene.assets.register(solidImage([255, 255, 255, 255]))
        let green = try scene.assets.register(solidImage([0, 255, 0, 255]))
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(9, at: .zero, radius: 8, filter: ghost, role: .static, render: blackID, decal: .image(solid)))
            .add(B.box(1, at: [3, 0], half: [3, 3], filter: ghost, render: redID)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([-3, 0], white, "naklejka bańki nad bańką")
        scene.assertPixel([3, 0], red, "bryła przykrywa bańkę razem z naklejką, choć ma mniejszy ObjectID")
        scene.assertPixel([0, 6], white, "naklejka bańki poza bryłą")

        scene.world.submit(try WorldTransaction().setDecal(id(1), decal: .image(green)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([3, 0], RGBA(0, 1, 0), "naklejka bryły nad bryłą")
        scene.assertPixel([-3, 0], white, "naklejka bańki bez zmian")
    }

    func testBubbleDecalOnAHigherLayerCoversTheBodyBelow() async throws {
        let scene = try makeScene()
        let solid = try scene.assets.register(solidImage([255, 255, 255, 255]))
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: blackID, layer: 2, decal: .image(solid)))
            .add(B.box(2, at: .zero, half: [3, 3], filter: ghost, render: redID, layer: 0)))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], white, "wyższa warstwa z naklejką nad bryłą z niższej")
    }

    // MARK: P-B-48 — zmiana naklejki, odrzucenie, scalenie i podział

    func testNewDecalIsDrawnInTheFirstFrameWithItsReceiptAndARejectedOneChangesNothing() async throws {
        let scene = try makeScene()
        let redImage = try scene.assets.register(solidImage([255, 0, 0, 255]))
        let greenImage = try scene.assets.register(solidImage([0, 255, 0, 255]))
        let missing = TextureID(rawValue: greenImage.rawValue + 100)
        scene.world.submit(try WorldTransaction().add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static,
                                                                render: blackID, decal: .image(redImage))))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], red, "początkowa naklejka")

        let change = scene.world.submit(try WorldTransaction().setDecal(id(1), decal: .image(greenImage)))
        // Klatka z krokiem: render zakodowany w tym samym buforze, przed publikacją, już pokazuje nową naklejkę.
        let stepFrame = try await scene.advanceRendering(by: 1.0 / 60)
        XCTAssertEqual(stepFrame.frame.transactionReceipts.map(\.token), [change], "klatka z potwierdzeniem")
        scene.assertPixel([0, 0], green, "nowa naklejka w klatce z krokiem, która niesie potwierdzenie")
        try await scene.render()
        scene.assertPixel([0, 0], green, "nowa naklejka po publikacji")

        let rejected = scene.world.submit(try WorldTransaction().setDecal(id(1), decal: .image(redImage))
            .setDecal(id(1), decal: .image(missing)))
        let rejectedFrame = await scene.step()
        XCTAssertEqual(rejectedFrame.events, [.transactionRejected(rejected,
            TransactionRejection(operationIndex: 1, reason: .textureNotFound(missing)))])
        try await scene.render()
        scene.assertPixel([0, 0], green, "odrzucona transakcja nic nie zmienia")

        scene.world.submit(try WorldTransaction().setDecal(id(1), decal: nil))
        await scene.step()
        try await scene.render()
        scene.assertPixel([0, 0], black, "usunięta naklejka")
    }

    func testMergeAndSplitResultsCarryTheDecalFromTheOperation() async throws {
        let scene = try makeScene()
        let blue = try scene.assets.register(solidImage([0, 0, 255, 255]))
        let green = try scene.assets.register(solidImage([0, 255, 0, 255]))
        let white = try scene.assets.register(solidImage([255, 255, 255, 255]))
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-3, 0], radius: 6, filter: ghost, render: blackID, decal: .image(white)))
            .add(B.bubble(2, at: [3, 0], radius: 6, filter: ghost, render: blackID, decal: .image(white))))
        await scene.step()
        let merged = BubbleResult(id: id(3), physicsMaterialID: B.bubbleMaterial, renderMaterialID: blackID, filter: ghost,
                                  decal: try .image(blue))
        scene.world.submit(WorldTransaction().mergeBubbles([id(1), id(2)], result: merged))
        let mergeFrame = await scene.step()
        let center = try XCTUnwrap(mergeFrame.objects[id(3)]).position
        try await scene.render()
        scene.assertPixel(center, RGBA(0, 0, 1), "wynik scalenia ma naklejkę z operacji, nie ze źródeł")

        let first = BubbleSplitPart(result: BubbleResult(id: id(4), physicsMaterialID: B.bubbleMaterial, renderMaterialID: blackID,
                                                         filter: ghost, decal: try .image(green)), share: 0.5)
        let second = BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: B.bubbleMaterial, renderMaterialID: blackID,
                                                          filter: ghost, decal: nil), share: 0.5)
        scene.world.submit(WorldTransaction().splitBubble(id(3), first: first, second: second))
        let splitFrame = await scene.step()
        let a = try XCTUnwrap(splitFrame.objects[id(4)]).position, b = try XCTUnwrap(splitFrame.objects[id(5)]).position
        try await scene.render()
        scene.assertPixel(a, RGBA(0, 1, 0), "część podziału z naklejką")
        scene.assertPixel(b, black, "część podziału bez naklejki")
    }
}
