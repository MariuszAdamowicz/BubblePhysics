import Metal

/// Metryki jednego glifu w atlasie, w tekselach tekstury atlasu (te same jednostki co `GlyphAtlas.ascent`). Układ glifów
/// skaluje je tak, że wysokość linii (`ascent + descent`) odpowiada promieniowi odniesienia naklejki razy jej skala.
public struct GlyphMetrics: Equatable, Sendable {
    /// Lewy górny róg prostokąta glifu w teksturze (Y w dół); prostokąt leży w całości w teksturze.
    public let origin: SIMD2<Float>
    /// Wielkość prostokąta w teksturze, a zarazem czworokąta glifu na ekranie.
    public let size: SIMD2<Float>
    /// Przesunięcie lewego dolnego rogu czworokąta względem pióra na linii bazowej (Y w górę).
    public let offset: SIMD2<Float>
    /// Przesuw pióra po glifie.
    public let advance: Float

    public init(origin: SIMD2<Float>, size: SIMD2<Float>, offset: SIMD2<Float>, advance: Float) {
        self.origin = origin; self.size = size; self.offset = offset; self.advance = advance
    }
}

/// Atlas glifów: tekstura `r8Unorm` (pokrycie w kanale czerwonym) i metryki na znak. Wspólny dla obu źródeł naklejki
/// tekstowej: atlas SDF z czcionki i gotowy atlas gry.
public struct GlyphAtlas {
    public let texture: MTLTexture
    public let glyphs: [Character: GlyphMetrics]
    /// Wysokość nad linią bazową i pod nią, w jednostkach atlasu; ich suma to wysokość linii.
    public let ascent: Float
    public let descent: Float
    /// Prawda, gdy tekstura trzyma odległość ze znakiem (0,5 na krawędzi glifu), fałsz, gdy zwykłe pokrycie (alfę).
    public let isSignedDistanceField: Bool

    public init(texture: MTLTexture, glyphs: [Character: GlyphMetrics], ascent: Float, descent: Float,
                isSignedDistanceField: Bool = false) {
        self.texture = texture; self.glyphs = glyphs; self.ascent = ascent; self.descent = descent
        self.isSignedDistanceField = isSignedDistanceField
    }

    public var lineHeight: Float { ascent + descent }
}
