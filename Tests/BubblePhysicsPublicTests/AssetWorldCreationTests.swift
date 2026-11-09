import BubblePhysics
import BubblePhysicsAssets
import Metal
import XCTest

/// P-B-39: świat dostaje rejestr przy tworzeniu; rejestr innego urządzenia to błąd; transakcja widzi tylko zarejestrowane tekstury.
@MainActor
final class AssetWorldCreationTests: XCTestCase {
    private var device: MTLDevice!
    private let step = 1.0 / 60

    override func setUpWithError() throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice(), "Wymaga urządzenia Metal")
    }

    private func configuration() throws -> WorldConfiguration {
        try WorldConfiguration(simulationRegion: WorldRectangle(min: [0, 0], max: [100, 100]), fixedTimeStep: step)
    }

    private func texture() throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: 4, height: 4, mipmapped: false)
        descriptor.usage = .shaderRead
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    func testWorldWithoutRegistryGetsAnEmptyRegistryOfItsDevice() throws {
        let world = try BubbleWorld(configuration: configuration(), device: device)
        let registry = try XCTUnwrap(world.assets)
        XCTAssertTrue(registry.device === device)
        XCTAssertFalse(registry.contains(TextureID(rawValue: 1)))
    }

    func testWorldKeepsTheRegistryItWasGiven() throws {
        let registry = AssetRegistry(device: device)
        let world = try BubbleWorld(configuration: configuration(), device: device, assets: registry)
        XCTAssertTrue(world.assets === registry)
    }

    func testRegistryOfAnotherDeviceIsAnErrorAtCreation() throws {
        let foreign = AssetRegistry(device: device, deviceRegistryID: device.registryID &+ 1)
        XCTAssertThrowsError(try BubbleWorld(configuration: configuration(), device: device, assets: foreign)) {
            XCTAssertEqual($0 as? AssetError, .deviceMismatch)
        }
    }

    func testRegistryWithoutWorldDeviceIsAnErrorAtCreation() throws {
        XCTAssertThrowsError(try BubbleWorld(configuration: configuration(), device: nil, assets: AssetRegistry(device: device))) {
            XCTAssertEqual($0 as? AssetError, .deviceMismatch)
        }
    }

    func testTransactionSeesOnlyTexturesRegisteredInTheWorldRegistry() async throws {
        let registry = AssetRegistry(device: device)
        let world = try BubbleWorld(configuration: configuration(), device: device, assets: registry)
        let known = try registry.register(texture())
        let unknown = TextureID(rawValue: known.rawValue + 100)
        let accepted = world.submit(WorldTransaction()
            .updateRenderMaterial(RenderMaterialID(rawValue: 1), material: try RenderMaterial(texture: known))
            .setBackground(known))
        let rejected = world.submit(WorldTransaction()
            .updateRenderMaterial(RenderMaterialID(rawValue: 2), material: try RenderMaterial(texture: unknown)))
        let rejectedBackground = world.submit(WorldTransaction().setBackground(unknown))
        let frame = await world.advance(by: step)
        XCTAssertEqual(frame.transactionReceipts.map(\.token), [accepted])
        XCTAssertEqual(frame.events, [
            .transactionRejected(rejected, TransactionRejection(operationIndex: 0, reason: .textureNotFound(unknown))),
            .transactionRejected(rejectedBackground, TransactionRejection(operationIndex: 0, reason: .textureNotFound(unknown)))])
    }

    /// P-B-49: stager świata dostaje glify z rejestru świata; znak spoza zestawu i niezarejestrowane źródło odrzucają transakcję.
    func testTransactionSeesOnlyGlyphSourcesAndCharactersRegisteredInTheWorldRegistry() async throws {
        let registry = AssetRegistry(device: device)
        let world = try BubbleWorld(configuration: configuration(), device: device, assets: registry)
        let font = try registry.register(font: "Helvetica", characters: "0123")
        let missingFont = FontID(rawValue: font.rawValue + 100)
        let physics = PhysicsMaterialID(rawValue: 1), look = RenderMaterialID(rawValue: 1), object = ObjectID(rawValue: 1)
        let setup = world.submit(WorldTransaction()
            .updatePhysicsMaterial(physics, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(look, material: try RenderMaterial())
            .add(.bubble(try BubbleDescriptor(id: object, position: [50, 50], targetRadius: 5,
                                              physicsMaterialID: physics, renderMaterialID: look))))
        let accepted = world.submit(try WorldTransaction().setDecal(object, decal: .text("0123", source: .font(font))))
        let badCharacter = world.submit(try WorldTransaction().setDecal(object, decal: .text("012x", source: .font(font))))
        let badFont = world.submit(try WorldTransaction().setDecal(object, decal: .text("0", source: .font(missingFont))))
        let frame = await world.advance(by: step)
        XCTAssertEqual(frame.transactionReceipts.map(\.token), [setup, accepted])
        XCTAssertEqual(frame.events, [
            .transactionRejected(badCharacter, TransactionRejection(operationIndex: 0, reason: .characterNotInGlyphSet("x"))),
            .transactionRejected(badFont, TransactionRejection(operationIndex: 0, reason: .fontNotFound(missingFont)))])
    }
}
