import CoreGraphics
import Metal
import BubblePhysicsModel

/// Błąd rejestracji zasobu albo użycia rejestru z niewłaściwym urządzeniem.
public enum AssetError: Error, Equatable, Sendable {
    case unsupportedImage
    case unsupportedTexture
    case deviceMismatch
    case textureCreationFailed
}

/// Rejestr tekstur gry dla jednego urządzenia Metal. Rejestracja jest synchroniczna i dzieje się poza klatką.
@MainActor
public final class AssetRegistry {
    public let device: MTLDevice
    package let deviceRegistryID: UInt64

    public init(device: MTLDevice) {
        self.device = device
        self.deviceRegistryID = device.registryID
    }

    /// Szew testowy: rejestr podający się za inne urządzenie (komputer ma jedno `MTLDevice`).
    package init(device: MTLDevice, deviceRegistryID: UInt64) {
        self.device = device
        self.deviceRegistryID = deviceRegistryID
    }

    public func register(_ image: CGImage) throws -> TextureID { TextureID(rawValue: 0) }
    public func register(_ texture: MTLTexture) throws -> TextureID { TextureID(rawValue: 0) }
    public func contains(_ id: TextureID) -> Bool { false }
    package func texture(for id: TextureID) -> MTLTexture? { nil }
}
