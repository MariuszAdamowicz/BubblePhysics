import BubblePhysicsAssets
import BubblePhysicsModel
import BubblePhysicsNativeMetal
import Metal

/// Tekstura, z której czyta ciąg naklejek: zwykła tekstura gry (obraz) albo atlas glifów czcionki lub gry.
enum DecalTexture: Hashable {
    case texture(TextureID)
    case atlas(GlyphSource)
}

/// Układa naklejkę w czworokąty: glify tekstu wyśrodkowane w kotwicy i fragment obrazu. Położenia są w jednostkach promienia
/// odniesienia względem kotwicy (shader mnoży je przez promień i obraca z bryłą), więc dla bańki, której promień
/// docelowy shader czyta z rekordu na GPU, nic nie trzeba liczyć na CPU.
@MainActor
struct DecalRenderer {
    let assets: AssetRegistry
    /// Układ tekstu zależy od atlasu i napisu, które powtarzają się między naklejkami klatki, więc raz na klatkę wystarczy
    /// jedno wyszukanie zamiast atlasu i glifu na każdy znak każdej naklejki. Renderer żyje jedną klatkę, więc rejestr
    /// nie zmienia się pod pamięcią podręczną.
    private let textCache = TextCache()

    private final class TextCache {
        struct Key: Hashable { let source: GlyphSource; let string: String }
        struct Entry { let atlas: GlyphAtlas; let glyphs: [GlyphMetrics]; let totalAdvance: Float }
        var entries: [Key: Entry?] = [:]
    }

    struct Layout {
        let instance: NativeDecalInstance
        let vertices: [NativeDecalVertex]
        let texture: DecalTexture
    }

    /// `placement` niesie promień odniesienia bryły w `z`; kotwicę, obrót i interpolację daje shaderowi rekord bryły (`bodyIndex`, waga w `alpha`) albo bańki. `nil`, gdy zasób
    /// naklejki zniknął z rejestru (stager tego nie przepuszcza) albo tekst nie ma żadnego glifu.
    func layout(_ decal: Decal, placement: SIMD4<Float>, bubbleIndex: UInt32, previousBubbleIndex: UInt32 = NativeDecalInstance.noPrevious,
                alpha: Float = 1, bodyIndex: UInt32 = 0, instanceIndex: UInt32) -> Layout? {
        let tint = SIMD4(decal.color.red, decal.color.green, decal.color.blue, decal.color.alpha)
        switch decal.content {
        case .image(let textureID, let region):
            guard let texture = assets.texture(for: textureID) else { return nil }
            // Fragment mieści się w kwadracie o boku 2·skala promieni; dłuższy bok go wypełnia, proporcje fragmentu zostają.
            let width = (region.max.x - region.min.x) * Float(texture.width)
            let height = (region.max.y - region.min.y) * Float(texture.height)
            let longest = max(width, height)
            let halfWidth = decal.scale * width / longest, halfHeight = decal.scale * height / longest
            let vertices = Self.quad(left: -halfWidth, bottom: -halfHeight, right: halfWidth, top: halfHeight,
                                     uvMin: region.min, uvMax: region.max, instance: instanceIndex)
            return Layout(instance: NativeDecalInstance(color: tint, placement: placement, bubbleIndex: bubbleIndex, mode: .image,
                                                 previousBubbleIndex: previousBubbleIndex, alpha: alpha, bodyIndex: bodyIndex),
                          vertices: vertices, texture: .texture(textureID))
        case .text(let string, let source):
            guard let entry = textEntry(string, source) else { return nil }
            let atlas = entry.atlas, glyphs = entry.glyphs, totalAdvance = entry.totalAdvance
            // Wysokość linii to promień odniesienia razy skala; jednostka atlasu to więc skala / wysokość linii promienia.
            let unit = decal.scale / atlas.lineHeight
            // Linia wyśrodkowana w kotwicy: poziomo po sumie przesuwów, pionowo po pudle linii (ascent nad linią bazową,
            // descent pod nią).
            var penX = -totalAdvance * unit / 2
            let baseline = -(atlas.ascent - atlas.descent) / 2 * unit
            let textureSize = SIMD2(Float(atlas.texture.width), Float(atlas.texture.height))
            var vertices: [NativeDecalVertex] = []
            vertices.reserveCapacity(glyphs.count * 6)
            for metrics in glyphs {
                let left = penX + metrics.offset.x * unit, bottom = baseline + metrics.offset.y * unit
                let uvMin = metrics.origin / textureSize, uvMax = (metrics.origin + metrics.size) / textureSize
                vertices += Self.quad(left: left, bottom: bottom, right: left + metrics.size.x * unit,
                                      top: bottom + metrics.size.y * unit, uvMin: uvMin, uvMax: uvMax, instance: instanceIndex)
                penX += metrics.advance * unit
            }
            let mode: NativeDecalInstance.Mode = atlas.isSignedDistanceField ? .glyphDistanceField : .glyphAlpha
            return Layout(instance: NativeDecalInstance(color: tint, placement: placement, bubbleIndex: bubbleIndex, mode: mode,
                                                 previousBubbleIndex: previousBubbleIndex, alpha: alpha, bodyIndex: bodyIndex),
                          vertices: vertices, texture: .atlas(source))
        }
    }

    /// Atlas, glify napisu i suma ich przesuwów; `nil`, gdy źródła nie ma w rejestrze albo napis nie ma żadnego glifu.
    private func textEntry(_ string: String, _ source: GlyphSource) -> TextCache.Entry? {
        let key = TextCache.Key(source: source, string: string)
        if let cached = textCache.entries[key] { return cached }
        var entry: TextCache.Entry?
        if let atlas = assets.atlas(for: source) {
            let glyphs = string.compactMap { character in atlas.glyphs[character] }
            if !glyphs.isEmpty {
                entry = .init(atlas: atlas, glyphs: glyphs, totalAdvance: glyphs.reduce(Float(0)) { $0 + $1.advance })
            }
        }
        textCache.entries[key] = .some(entry)
        return entry
    }

    /// Dwa trójkąty; wiersz 0 tekstury (`uvMin.y`) leży na górze czworokąta.
    private static func quad(left: Float, bottom: Float, right: Float, top: Float, uvMin: SIMD2<Float>, uvMax: SIMD2<Float>,
                             instance: UInt32) -> [NativeDecalVertex] {
        func vertex(_ x: Float, _ y: Float, _ u: Float, _ v: Float) -> NativeDecalVertex {
            NativeDecalVertex(local: SIMD2(x, y), uv: SIMD2(u, v), instance: instance)
        }
        let topLeft = vertex(left, top, uvMin.x, uvMin.y), topRight = vertex(right, top, uvMax.x, uvMin.y)
        let bottomRight = vertex(right, bottom, uvMax.x, uvMax.y), bottomLeft = vertex(left, bottom, uvMin.x, uvMax.y)
        return [topLeft, topRight, bottomRight, topLeft, bottomRight, bottomLeft]
    }
}
