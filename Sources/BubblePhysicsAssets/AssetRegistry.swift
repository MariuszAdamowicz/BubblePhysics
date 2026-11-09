import CoreGraphics
import Metal
import BubblePhysicsModel

/// Błąd rejestracji zasobu albo użycia rejestru z niewłaściwym urządzeniem.
public enum AssetError: Error, Equatable, Sendable {
    /// Obraz bez kolorów (maska), pusty albo większy niż tekstura 2D Metal.
    case unsupportedImage
    /// Tekstura, która nie jest próbkowalną teksturą 2D w formacie 8-bitowym RGBA lub BGRA (bez wariantów `_srgb`).
    case unsupportedTexture
    /// Zasób albo rejestr należy do innego `MTLDevice` niż świat lub tekstura.
    case deviceMismatch
    case textureCreationFailed
    /// Czcionka o tej nazwie nie jest dostępna w systemie ani w pakiecie aplikacji.
    case fontNotFound
    /// Atlas glifów bez tekstury `r8Unorm` do odczytu, bez glifów albo z metryką spoza tekstury.
    case invalidGlyphAtlas
}

/// Rejestr tekstur gry dla jednego urządzenia Metal. Rejestracja jest synchroniczna i dzieje się poza klatką,
/// więc dekodowanie obrazu nie trafia na ścieżkę kroku. Transakcje wskazują tekstury tylko przez `TextureID`.
@MainActor
public final class AssetRegistry {
    /// Największy wymiar tekstury 2D, który obsługują wszystkie wspierane urządzenia (A11 i nowsze).
    package static let maximumTextureDimension = 16384

    public let device: MTLDevice
    /// Urządzenia porównuje się po `registryID`, a nie po tożsamości obiektu.
    package let deviceRegistryID: UInt64
    private var textures: [TextureID: MTLTexture] = [:]
    private var nextID: UInt64 = 1

    public init(device: MTLDevice) {
        self.device = device
        self.deviceRegistryID = device.registryID
    }

    /// Szew testowy: rejestr podający się za inne urządzenie (komputer ma jedno `MTLDevice`).
    package init(device: MTLDevice, deviceRegistryID: UInt64) {
        self.device = device
        self.deviceRegistryID = deviceRegistryID
    }

    /// Dekoduje obraz raz do `rgba8Unorm` (alfa przemnożona) i wysyła go do tekstury urządzenia.
    public func register(_ image: CGImage) throws -> TextureID {
        let width = image.width, height = image.height
        let limit = Self.maximumTextureDimension
        guard !image.isMask, image.colorSpace != nil, (1...limit).contains(width), (1...limit).contains(height) else {
            throw AssetError.unsupportedImage
        }
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn: Bool = bytes.withUnsafeMutableBytes { buffer in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: space,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw AssetError.unsupportedImage }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: width, height: height,
                                                                   mipmapped: false)
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw AssetError.textureCreationFailed }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: bytes, bytesPerRow: width * 4)
        return store(texture)
    }

    /// Przyjmuje gotową teksturę 2D z `shaderRead` w formacie 8-bitowym RGBA lub BGRA (`rgba8Unorm`, `bgra8Unorm`)
    /// tego samego urządzenia. Formaty `_srgb` są odrzucane (`unsupportedTexture`): potok liczy w przestrzeni celu renderu
    /// bez konwersji liniowej, a próbkowanie `_srgb` zwracałoby wartości liniowe.
    ///
    /// Kontrakt: tekstura ma **alfę przemnożoną** (premultiplied alpha), czyli składowe RGB są już pomnożone przez alfę.
    /// Shader dzieli RGB przez alfę w trybie nieprzezroczystym i mnoży RGB przez alfę koloru w trybach alfa i addytywnym;
    /// tekstura z alfą prostą (straight) wyglądałaby na ciemniejszą albo z prześwitującymi obwódkami. `register(_: CGImage)`
    /// przemnaża sam, ta metoda przyjmuje bajty bez zmian.
    public func register(_ texture: MTLTexture) throws -> TextureID {
        guard texture.device.registryID == deviceRegistryID else { throw AssetError.deviceMismatch }
        let formats: Set<MTLPixelFormat> = [.rgba8Unorm, .bgra8Unorm]
        guard texture.textureType == .type2D, texture.sampleCount == 1, texture.usage.contains(.shaderRead),
              formats.contains(texture.pixelFormat) else { throw AssetError.unsupportedTexture }
        return store(texture)
    }

    /// Czy `id` jest zarejestrowany; stager pyta o to przy walidacji transakcji.
    public func contains(_ id: TextureID) -> Bool { textures[id] != nil }

    package func texture(for id: TextureID) -> MTLTexture? { textures[id] }

    /// Rejestruje czcionkę o danej nazwie z zestawem znaków i raz generuje jej atlas SDF.
    public func register(font name: String, characters: String) throws -> FontID {
        throw AssetError.fontNotFound
    }

    /// Przyjmuje gotowy atlas glifów gry (tekstura i metryki) tego samego urządzenia.
    public func register(glyphAtlas: GlyphAtlas) throws -> GlyphAtlasID {
        throw AssetError.invalidGlyphAtlas
    }

    /// Czy źródło glifów jest zarejestrowane; stager pyta o to przy walidacji naklejki.
    package func contains(_ source: GlyphSource) -> Bool { false }

    /// Atlas źródła glifów; renderer rysuje z jego tekstury.
    package func atlas(for source: GlyphSource) -> GlyphAtlas? { nil }

    /// Metryki znaku w źródle; `nil`, gdy źródła albo znaku nie ma.
    package func glyph(_ character: Character, in source: GlyphSource) -> GlyphMetrics? { nil }

    private func store(_ texture: MTLTexture) -> TextureID {
        let id = TextureID(rawValue: nextID)
        nextID += 1
        textures[id] = texture
        return id
    }
}
