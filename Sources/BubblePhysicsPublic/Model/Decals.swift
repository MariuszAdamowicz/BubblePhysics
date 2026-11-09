/// Tekstura zarejestrowana w rejestrze zasobów urządzenia. Identyfikator nadaje rejestr, nie gra.
public struct TextureID: Hashable, Sendable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Czcionka zarejestrowana w rejestrze zasobów urządzenia (atlas SDF powstaje raz, w wywołaniu rejestracji).
public struct FontID: Hashable, Sendable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Gotowy atlas glifów zarejestrowany w rejestrze zasobów urządzenia.
public struct GlyphAtlasID: Hashable, Sendable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Skąd naklejka tekstowa bierze glify: z czcionki (atlas SDF generowany przy rejestracji) albo z gotowego atlasu gry.
public enum GlyphSource: Hashable, Sendable {
    case font(FontID)
    case atlas(GlyphAtlasID)
}

/// Prostokąt w teksturze we współrzędnych znormalizowanych [0, 1]; (0, 0) to lewy górny róg obrazu, V rośnie w dół.
public struct TextureRegion: Equatable, Hashable, Sendable {
    public let min: SIMD2<Float>
    public let max: SIMD2<Float>
    /// Cała tekstura.
    public static let full = TextureRegion(uncheckedMin: .zero, max: SIMD2(1, 1))

    /// Skończony, niepusty prostokąt w obrębie tekstury.
    public init(min: SIMD2<Float>, max: SIMD2<Float>) throws {
        try requireFinite(min, "textureRegion.min")
        try requireFinite(max, "textureRegion.max")
        guard min.x >= 0, min.y >= 0, max.x <= 1, max.y <= 1, min.x < max.x, min.y < max.y else {
            throw ModelValidationError.valueOutOfRange("textureRegion")
        }
        self.min = min; self.max = max
    }

    private init(uncheckedMin: SIMD2<Float>, max: SIMD2<Float>) { self.min = uncheckedMin; self.max = max }
}

/// Naklejka przypięta do bańki albo bryły: tekst z glifów albo fragment tekstury gry. Kotwica leży w środku obiektu,
/// a skala jest względna do promienia odniesienia (bańka: efektywny promień; bryła: promień okręgu opisanego).
/// Naklejka jest zawsze przycinana do koła o promieniu odniesienia, na bańce także do jej konturu.
public struct Decal: Equatable, Sendable {
    public enum Content: Equatable, Sendable {
        case text(String, source: GlyphSource)
        case image(TextureID, region: TextureRegion)
    }

    /// Wartości trzyma jeden niezmienny obiekt, więc kopia deskryptora z naklejką (albo bez niej) to jedno zliczenie
    /// referencji, a nie kopia napisu i wariantu: deskryptory baniek są kopiowane w każdym kroku.
    private final class Storage: Sendable {
        let content: Content
        let color: RGBA
        let scale: Float
        init(content: Content, color: RGBA, scale: Float) { self.content = content; self.color = color; self.scale = scale }
    }

    private let storage: Storage

    public var content: Content { storage.content }
    public var color: RGBA { storage.color }
    /// Skończona i dodatnia; wysokość linii tekstu to promień odniesienia razy skala, obraz zajmuje koło o tym promieniu razy skala.
    public var scale: Float { storage.scale }

    public init(_ content: Content, color: RGBA = .white, scale: Float = 1) throws {
        try color.validate("decal.color")
        try requirePositive(scale, "decal.scale")
        storage = Storage(content: content, color: color, scale: scale)
    }

    public static func == (lhs: Decal, rhs: Decal) -> Bool {
        lhs.storage === rhs.storage
            || (lhs.content == rhs.content && lhs.color == rhs.color && lhs.scale == rhs.scale)
    }

    public static func text(_ string: String, source: GlyphSource, color: RGBA = .white, scale: Float = 1) throws -> Decal {
        try Decal(.text(string, source: source), color: color, scale: scale)
    }

    public static func image(_ texture: TextureID, region: TextureRegion = .full, color: RGBA = .white,
                             scale: Float = 1) throws -> Decal {
        try Decal(.image(texture, region: region), color: color, scale: scale)
    }
}

/// Domknięcie z rejestru zasobów dla stagera: dla źródła glifów zwraca test przynależności znaku do jego zestawu albo `nil`,
/// gdy źródło nie jest zarejestrowane. Runtime nie zna rejestru, więc dostaje to jak `textureExists`.
package typealias GlyphLookup = (GlyphSource) -> ((Character) -> Bool)?
