import BubblePhysicsAssets
import BubblePhysicsModel
import Metal
import XCTest

/// P-B-43 (rejestracja czcionki), P-B-44 (gotowy atlas): rejestracja glifów w jednym wywołaniu, poza transakcją;
/// błędy w samym wywołaniu.
@MainActor
final class GlyphRegistryTests: XCTestCase {
    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Wymaga urządzenia Metal")
    }

    private func texture(format: MTLPixelFormat = .r8Unorm, type: MTLTextureType = .type2D,
                         usage: MTLTextureUsage = .shaderRead, size: Int = 16) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = type
        descriptor.pixelFormat = format
        descriptor.width = size; descriptor.height = size
        if type == .type3D { descriptor.depth = 2 }
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    /// Atlas 16×16 z glifami "A" (lewa połowa) i "B" (prawa połowa).
    private func readyAtlas(texture: MTLTexture? = nil, ascent: Float = 10, descent: Float = 2,
                            glyphs: [Character: GlyphMetrics]? = nil) throws -> GlyphAtlas {
        let defaults: [Character: GlyphMetrics] = [
            "A": GlyphMetrics(origin: [0, 0], size: [8, 16], offset: [0, -2], advance: 9),
            "B": GlyphMetrics(origin: [8, 0], size: [8, 16], offset: [0, -2], advance: 9)]
        return GlyphAtlas(texture: try texture ?? self.texture(), glyphs: glyphs ?? defaults,
                          ascent: ascent, descent: descent, isSignedDistanceField: false)
    }

    // MARK: czcionka

    func testSystemFontWithACharacterSetGetsAFontIDAndAnSDFAtlasWithMetrics() throws {
        let registry = AssetRegistry(device: device)
        let id = try registry.register(font: "Helvetica", characters: "0123456789AB")
        XCTAssertTrue(registry.contains(.font(id)))
        let atlas = try XCTUnwrap(registry.atlas(for: .font(id)))
        for character in "0123456789AB" {
            let metrics = try XCTUnwrap(registry.glyph(character, in: .font(id)), "brak glifu \(character)")
            XCTAssertGreaterThan(metrics.size.x, 0, "glif \(character)")
            XCTAssertGreaterThan(metrics.size.y, 0)
            XCTAssertGreaterThan(metrics.advance, 0)
            XCTAssertGreaterThanOrEqual(metrics.origin.x, 0)
            XCTAssertGreaterThanOrEqual(metrics.origin.y, 0)
            XCTAssertLessThanOrEqual(metrics.origin.x + metrics.size.x, Float(atlas.texture.width))
            XCTAssertLessThanOrEqual(metrics.origin.y + metrics.size.y, Float(atlas.texture.height))
        }
        XCTAssertNil(registry.glyph("Z", in: .font(id)), "znak spoza zestawu nie ma glifu")
        XCTAssertTrue(atlas.isSignedDistanceField)
        XCTAssertEqual(atlas.texture.pixelFormat, .r8Unorm)
        XCTAssertEqual(atlas.lineHeight, 32, accuracy: 1e-3, "skala 1× to glif o wysokości linii 32 px")
        XCTAssertGreaterThan(atlas.ascent, 0)
        XCTAssertGreaterThan(atlas.descent, 0)
    }

    func testFontAtlasHoldsADistanceFieldNotACoverageMask() throws {
        let registry = AssetRegistry(device: device)
        let id = try registry.register(font: "Helvetica", characters: "I")
        let atlas = try XCTUnwrap(registry.atlas(for: .font(id)))
        let metrics = try XCTUnwrap(atlas.glyphs["I"])
        let width = atlas.texture.width, height = atlas.texture.height
        var bytes = [UInt8](repeating: 0, count: width * height)
        atlas.texture.getBytes(&bytes, bytesPerRow: width, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        let inside = Set(bytes.filter { $0 > 127 }), distinct = Set(bytes)
        XCTAssertFalse(inside.isEmpty, "wnętrze glifu (odległość > 0,5)")
        XCTAssertGreaterThan(distinct.count, 8, "pole odległości ma stopniowane wartości, nie samo 0 i 255")
        // Środek glifu "I" leży wewnątrz, narożnik tekstury poza.
        let cx = Int(metrics.origin.x + metrics.size.x / 2)
        let cy = Int(metrics.origin.y + metrics.size.y / 2)
        XCTAssertGreaterThan(bytes[cy * width + cx], 127)
        XCTAssertLessThan(bytes[0], 127)
    }

    func testUnknownFontNameIsAnErrorInTheRegistrationCall() throws {
        let registry = AssetRegistry(device: device)
        XCTAssertThrowsError(try registry.register(font: "Nie Ma Takiej Czcionki 9000", characters: "A")) {
            XCTAssertEqual($0 as? AssetError, .fontNotFound)
        }
    }

    func testFontsGetDistinctIDsAndKeepTheirOwnCharacterSets() throws {
        let registry = AssetRegistry(device: device)
        let digits = try registry.register(font: "Helvetica", characters: "012")
        let letters = try registry.register(font: "Helvetica", characters: "AB")
        XCTAssertNotEqual(digits, letters)
        XCTAssertNotNil(registry.glyph("1", in: .font(digits)))
        XCTAssertNil(registry.glyph("A", in: .font(digits)))
        XCTAssertNotNil(registry.glyph("A", in: .font(letters)))
        XCTAssertNil(registry.glyph("1", in: .font(letters)))
    }

    func testEmptyCharacterSetIsRejectedBecauseThereWouldBeNothingToDraw() throws {
        let registry = AssetRegistry(device: device)
        XCTAssertThrowsError(try registry.register(font: "Helvetica", characters: "")) {
            XCTAssertEqual($0 as? AssetError, .invalidGlyphAtlas)
        }
    }

    // MARK: gotowy atlas

    func testReadyAtlasGetsAGlyphAtlasIDAndIsLookedUpPerSource() throws {
        let registry = AssetRegistry(device: device)
        let font = try registry.register(font: "Helvetica", characters: "0123")
        let atlasValue = try readyAtlas()
        let id = try registry.register(glyphAtlas: atlasValue)
        XCTAssertTrue(registry.contains(.atlas(id)))
        XCTAssertFalse(registry.contains(.atlas(GlyphAtlasID(rawValue: 9999))))
        XCTAssertEqual(registry.glyph("A", in: .atlas(id)), atlasValue.glyphs["A"])
        XCTAssertEqual(registry.glyph("B", in: .atlas(id)), atlasValue.glyphs["B"])
        XCTAssertNil(registry.glyph("0", in: .atlas(id)), "cyfra jest w czcionce, nie w atlasie")
        XCTAssertNil(registry.glyph("A", in: .font(font)))
        let stored = try XCTUnwrap(registry.atlas(for: .atlas(id)))
        XCTAssertTrue(stored.texture === atlasValue.texture)
        XCTAssertEqual(stored.lineHeight, 12)
        XCTAssertFalse(stored.isSignedDistanceField)
        XCTAssertNotEqual(try registry.register(glyphAtlas: atlasValue), id)
    }

    func testAtlasWithAMetricOutsideTheTextureIsInvalid() throws {
        let registry = AssetRegistry(device: device)
        // Tekstura ma 16×16 teksli: ostatni poprawny prostokąt kończy się dokładnie na krawędzi.
        let edge = GlyphMetrics(origin: [8, 0], size: [8, 16], offset: .zero, advance: 9)
        XCTAssertNoThrow(try registry.register(glyphAtlas: readyAtlas(glyphs: ["A": edge])))
        let broken: [(String, GlyphMetrics)] = [
            ("poza prawą krawędzią", GlyphMetrics(origin: [9, 0], size: [8, 16], offset: .zero, advance: 9)),
            ("poza dolną krawędzią", GlyphMetrics(origin: [0, 1], size: [8, 16], offset: .zero, advance: 9)),
            ("ujemny początek", GlyphMetrics(origin: [-1, 0], size: [8, 16], offset: .zero, advance: 9)),
            ("zerowa szerokość", GlyphMetrics(origin: [0, 0], size: [0, 16], offset: .zero, advance: 9)),
            ("ujemna wysokość", GlyphMetrics(origin: [0, 0], size: [8, -1], offset: .zero, advance: 9)),
            ("rozmiar NaN", GlyphMetrics(origin: [0, 0], size: [.nan, 16], offset: .zero, advance: 9)),
            ("początek nieskończony", GlyphMetrics(origin: [.infinity, 0], size: [8, 16], offset: .zero, advance: 9)),
            ("przesunięcie nieskończone", GlyphMetrics(origin: [0, 0], size: [8, 16], offset: [.infinity, 0], advance: 9)),
            ("ujemny przesuw", GlyphMetrics(origin: [0, 0], size: [8, 16], offset: .zero, advance: -1)),
            ("przesuw NaN", GlyphMetrics(origin: [0, 0], size: [8, 16], offset: .zero, advance: .nan))]
        for (name, metrics) in broken {
            XCTAssertThrowsError(try registry.register(glyphAtlas: readyAtlas(glyphs: ["A": metrics])), name) {
                XCTAssertEqual($0 as? AssetError, .invalidGlyphAtlas, name)
            }
        }
    }

    func testAtlasWithAnUnusableTextureOrHeightsIsInvalid() throws {
        let registry = AssetRegistry(device: device)
        let cases: [(String, GlyphAtlas)] = try [
            ("rgba zamiast r8", readyAtlas(texture: texture(format: .rgba8Unorm))),
            ("bez shaderRead", readyAtlas(texture: texture(usage: .renderTarget))),
            ("trójwymiarowa", readyAtlas(texture: texture(type: .type3D))),
            ("brak glifów", readyAtlas(glyphs: [:])),
            ("zerowa wysokość linii", readyAtlas(ascent: 0, descent: 0)),
            ("ujemny descent", readyAtlas(ascent: 10, descent: -1)),
            ("nieskończony ascent", readyAtlas(ascent: .infinity))]
        for (name, atlas) in cases {
            XCTAssertThrowsError(try registry.register(glyphAtlas: atlas), name) {
                XCTAssertEqual($0 as? AssetError, .invalidGlyphAtlas, name)
            }
        }
    }

    func testAtlasTextureFromAnotherDeviceIsADeviceMismatch() throws {
        let other = AssetRegistry(device: device, deviceRegistryID: device.registryID &+ 1)
        XCTAssertThrowsError(try other.register(glyphAtlas: readyAtlas())) {
            XCTAssertEqual($0 as? AssetError, .deviceMismatch)
        }
    }

    func testIDsOfOneRegistryAreNotKnownToAnother() throws {
        let registry = AssetRegistry(device: device)
        let other = AssetRegistry(device: device)
        let font = try other.register(font: "Helvetica", characters: "A")
        let atlas = try other.register(glyphAtlas: readyAtlas())
        XCTAssertFalse(registry.contains(.font(font)))
        XCTAssertFalse(registry.contains(.atlas(atlas)))
        XCTAssertNil(registry.glyph("A", in: .font(font)))
        XCTAssertNil(registry.atlas(for: .atlas(atlas)))
    }
}
