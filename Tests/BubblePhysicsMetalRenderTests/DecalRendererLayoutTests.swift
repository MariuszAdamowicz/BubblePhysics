import BubblePhysics
import BubblePhysicsAssets
import Metal
@testable import BubblePhysicsMetalRender
import XCTest

/// P-B-80 (etap 8): układ tekstu z pamięci podręcznej klatki jest bajt w bajt taki sam jak ze świeżego renderera,
/// a brak źródła albo glifów też daje `nil` przy powtórzeniu.
@MainActor
final class DecalRendererLayoutTests: XCTestCase {
    private func bytes<T>(_ values: [T]) -> [UInt8] { values.withUnsafeBytes { Array($0) } }

    func testRepeatedTextLayoutEqualsAFreshRenderersLayout() throws {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let font = try scene.assets.register(font: "Helvetica-Bold", characters: "0123456789")
        let source = GlyphSource.font(font)
        let cached = DecalRenderer(assets: scene.assets)
        for (index, text) in ["7", "42", "7", "9081", "42"].enumerated() {
            let decal = try Decal(.text(text, source: source), scale: 0.5 + Float(index) * 0.1)
            let reused = try XCTUnwrap(cached.layout(decal, placement: .zero, bubbleIndex: UInt32(index), instanceIndex: UInt32(index)))
            let fresh = try XCTUnwrap(DecalRenderer(assets: scene.assets).layout(
                decal, placement: .zero, bubbleIndex: UInt32(index), instanceIndex: UInt32(index)))
            XCTAssertEqual(bytes(reused.vertices), bytes(fresh.vertices), "napis \(text)")
            XCTAssertEqual(bytes([reused.instance]), bytes([fresh.instance]), "napis \(text)")
            XCTAssertEqual(reused.texture, fresh.texture)
        }
    }

    func testMissingSourceAndGlyphlessTextStayNilOnRepeat() throws {
        let scene = try RenderTestScene(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let font = try scene.assets.register(font: "Helvetica-Bold", characters: "0123456789")
        let renderer = DecalRenderer(assets: scene.assets)
        let noGlyphs = try Decal(.text("xyz", source: .font(font)))
        let unknown = try Decal(.text("1", source: .font(FontID(rawValue: 9_999))))
        for _ in 0..<2 {
            XCTAssertNil(renderer.layout(noGlyphs, placement: .zero, bubbleIndex: 0, instanceIndex: 0))
            XCTAssertNil(renderer.layout(unknown, placement: .zero, bubbleIndex: 0, instanceIndex: 0))
        }
    }
}
