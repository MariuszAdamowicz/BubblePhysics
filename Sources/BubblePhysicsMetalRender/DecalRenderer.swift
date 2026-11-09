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
/// efektywny zna tylko GPU, nic nie trzeba liczyć na CPU.
@MainActor
struct DecalRenderer {
    let assets: AssetRegistry

    struct Layout {
        let instance: NativeDecalInstance
        let vertices: [NativeDecalVertex]
        let texture: DecalTexture
    }

    /// `placement` to kotwica xy, promień odniesienia i obrót bryły; dla bańki ignorowane przez shader. `nil`, gdy zasób
    /// naklejki zniknął z rejestru (stager tego nie przepuszcza) albo tekst nie ma żadnego glifu.
    func layout(_ decal: Decal, placement: SIMD4<Float>, bubbleIndex: UInt32, instanceIndex: UInt32) -> Layout? {
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
            return Layout(instance: NativeDecalInstance(color: tint, placement: placement, bubbleIndex: bubbleIndex, mode: .image),
                          vertices: vertices, texture: .texture(textureID))
        case .text(let string, let source):
            guard let atlas = assets.atlas(for: source) else { return nil }
            // Wysokość linii to promień odniesienia razy skala; jednostka atlasu to więc skala / wysokość linii promienia.
            let unit = decal.scale / atlas.lineHeight
            let glyphs = string.compactMap { character in atlas.glyphs[character] }
            guard !glyphs.isEmpty else { return nil }
            let totalAdvance = glyphs.reduce(Float(0)) { $0 + $1.advance }
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
            return Layout(instance: NativeDecalInstance(color: tint, placement: placement, bubbleIndex: bubbleIndex, mode: mode),
                          vertices: vertices, texture: .atlas(source))
        }
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
