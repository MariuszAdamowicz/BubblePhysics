import BubblePhysicsAssets
import BubblePhysicsModel
import CoreGraphics
import Metal
import XCTest

/// P-B-39: rejestracja tekstur w jednym wywołaniu, poza transakcją; błędy w samym wywołaniu.
@MainActor
final class AssetRegistryTests: XCTestCase {
    private var device: MTLDevice!

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Wymaga urządzenia Metal")
    }

    /// Obraz RGB 8 bitów z nieprzezroczystymi pikselami o podanych kolorach, wiersz po wierszu od góry.
    private func image(width: Int, height: Int, pixels: [UInt8]) throws -> CGImage {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    private func metalTexture(format: MTLPixelFormat = .rgba8Unorm, type: MTLTextureType = .type2D,
                              usage: MTLTextureUsage = .shaderRead) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = type
        descriptor.pixelFormat = format
        descriptor.width = 4; descriptor.height = 4
        if type == .type3D { descriptor.depth = 2 }
        descriptor.usage = usage
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    func testRegistryBelongsToItsDevice() {
        let registry = AssetRegistry(device: device)
        XCTAssertTrue(registry.device === device)
        XCTAssertEqual(registry.deviceRegistryID, device.registryID)
    }

    func testCGImageIsDecodedOnceToRGBA8TextureAndGetsDistinctIDs() throws {
        let registry = AssetRegistry(device: device)
        // 2×2: czerwony, zielony / niebieski, biały.
        let source = try image(width: 2, height: 2, pixels: [
            255, 0, 0, 255, 0, 255, 0, 255,
            0, 0, 255, 255, 255, 255, 255, 255])
        let first = try registry.register(source)
        let second = try registry.register(source)
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(registry.contains(first))
        XCTAssertTrue(registry.contains(second))
        let texture = try XCTUnwrap(registry.texture(for: first))
        XCTAssertEqual(texture.pixelFormat, .rgba8Unorm)
        XCTAssertEqual(texture.textureType, .type2D)
        XCTAssertEqual([texture.width, texture.height], [2, 2])
        var pixels = [UInt8](repeating: 0, count: 16)
        texture.getBytes(&pixels, bytesPerRow: 8, from: MTLRegionMake2D(0, 0, 2, 2), mipmapLevel: 0)
        XCTAssertEqual(pixels, [255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 255])
    }

    func testMTLTextureIsRegisteredAsIs() throws {
        let registry = AssetRegistry(device: device)
        let texture = try metalTexture()
        let id = try registry.register(texture)
        XCTAssertTrue(registry.contains(id))
        XCTAssertTrue(registry.texture(for: id) === texture)
    }

    func testUnknownIDsAreNotContained() throws {
        let registry = AssetRegistry(device: device)
        let other = AssetRegistry(device: device)
        let id = try other.register(metalTexture())
        XCTAssertFalse(registry.contains(id))
        XCTAssertFalse(registry.contains(TextureID(rawValue: 12345)))
        XCTAssertNil(registry.texture(for: TextureID(rawValue: 12345)))
    }

    func testUnsupportedCGImageThrowsInTheRegisteringCall() throws {
        let registry = AssetRegistry(device: device)
        // Maska obrazu nie ma przestrzeni kolorów ani kolorów, więc nie jest teksturą.
        let maskData = try XCTUnwrap(CGDataProvider(data: Data([0, 255, 255, 0]) as CFData))
        let mask = try XCTUnwrap(CGImage(maskWidth: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: 2, provider: maskData, decode: nil, shouldInterpolate: false))
        XCTAssertThrowsError(try registry.register(mask)) { XCTAssertEqual($0 as? AssetError, .unsupportedImage) }
        // Szerokość ponad limit tekstury 2D Metal (16384).
        let wide = try image(width: 16385, height: 1, pixels: [UInt8](repeating: 255, count: 16385 * 4))
        XCTAssertThrowsError(try registry.register(wide)) { XCTAssertEqual($0 as? AssetError, .unsupportedImage) }
    }

    func testUnsupportedMTLTextureThrowsInTheRegisteringCall() throws {
        let registry = AssetRegistry(device: device)
        for texture in [try metalTexture(format: .r8Unorm),
                        try metalTexture(type: .type3D),
                        try metalTexture(usage: .renderTarget)] {
            XCTAssertThrowsError(try registry.register(texture)) { XCTAssertEqual($0 as? AssetError, .unsupportedTexture) }
        }
        XCTAssertNoThrow(try registry.register(metalTexture(format: .bgra8Unorm_srgb)))
    }

    func testTextureOfAnotherDeviceIsRejected() throws {
        // Mac ma jedno `MTLDevice`, więc „inne urządzenie” to rejestr z innym `registryID` (szew testowy).
        let foreign = AssetRegistry(device: device, deviceRegistryID: device.registryID &+ 1)
        XCTAssertThrowsError(try foreign.register(metalTexture())) { XCTAssertEqual($0 as? AssetError, .deviceMismatch) }
        XCTAssertNoThrow(try AssetRegistry(device: device).register(metalTexture()))
    }
}
