import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import CoreGraphics
import Metal
import XCTest

/// Wspólny render offscreen (256×256, `rgba8Unorm`) i próbkowanie pikseli dla testów obrazu.
/// Piksel porównuje się z tolerancją ±2/255 na kanał.
@MainActor
final class OffscreenRenderHarness {
    static let size = 256
    static let tolerance = 2

    let device: MTLDevice
    let size: Int
    let texture: MTLTexture
    private let queue: MTLCommandQueue

    init(device: MTLDevice, size: Int = 256) throws {
        self.device = device
        self.size = size
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: size, height: size,
                                                                   mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        queue = try XCTUnwrap(device.makeCommandQueue())
    }

    /// Przebieg renderu czyszczący cel do czerni.
    func makePass() -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    func makeCommandBuffer() throws -> MTLCommandBuffer { try XCTUnwrap(queue.makeCommandBuffer()) }

    /// Rysuje opublikowany stan świata do celu i czeka na koniec bufora.
    func render(world: BubbleWorld, renderer: BubblePhysicsMetalRender, viewport: Viewport) async throws {
        let command = try makeCommandBuffer()
        try renderer.encode(world: world, viewport: viewport, commandBuffer: command, renderPassDescriptor: makePass())
        command.commit()
        await command.completed()
        XCTAssertEqual(command.status, .completed)
    }

    func pixel(x: Int, y: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&result, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return result
    }

    /// Piksel w punkcie świata widzianym przez `viewport` (wiersz 0 to góra obrazu).
    func pixel(at point: WorldPoint, in viewport: Viewport) -> [UInt8] {
        let screen = (try? viewport.screenPoint(for: point, in: WorldPoint(Float(size), Float(size)))) ?? .zero
        let x = min(max(Int(screen.x.rounded(.down)), 0), size - 1)
        let y = min(max(Int(screen.y.rounded(.down)), 0), size - 1)
        return pixel(x: x, y: y)
    }

    func assertPixel(_ point: WorldPoint, _ viewport: Viewport, _ expected: RGBA, _ message: String = "",
                     file: StaticString = #filePath, line: UInt = #line) {
        let actual = pixel(at: point, in: viewport)
        let channels: [(String, Float)] = [("R", expected.red), ("G", expected.green), ("B", expected.blue)]
        for (index, channel) in channels.enumerated() {
            XCTAssertEqual(Int(actual[index]), Int((channel.1 * 255).rounded()), accuracy: Self.tolerance,
                "\(message) \(channel.0) w \(point): piksel \(actual.prefix(3)), oczekiwano \(expected)", file: file, line: line)
        }
    }

    /// Obraz `width`×`height` z nieprzezroczystymi pikselami, wiersz po wierszu od góry (RGBA).
    static func image(width: Int, height: Int, pixels: [[UInt8]]) throws -> CGImage {
        precondition(pixels.count == width * height)
        let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels.flatMap { $0 }) as CFData))
        return try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }

    /// Biały obraz 1×1: tylko łamie ciągi rysowania, a po pomnożeniu przez kolor nic nie zmienia.
    static func whiteImage() throws -> CGImage { try image(width: 1, height: 1, pixels: [[255, 255, 255, 255]]) }
}

/// Mała scena do testów obrazu: region ±50, kamera 40×40 w środku (6,4 piksela na jednostkę), jeden renderer z rejestrem
/// świata. Obiekty bez kolizji (maska 0), więc nic się nie rusza, a testy sprawdzają wyłącznie rysowanie.
@MainActor
struct RenderTestScene {
    static let viewport = try! Viewport(center: .zero, size: [40, 40])
    /// Obiekt, który z niczym nie koliduje.
    static let ghost = CollisionFilter(category: 1, mask: 0)

    let device: MTLDevice
    let world: BubbleWorld
    let renderer: BubblePhysicsMetalRender
    let harness: OffscreenRenderHarness
    var assets: AssetRegistry { world.assets! }

    init(device: MTLDevice, region: WorldRectangle? = nil) throws {
        self.device = device
        world = try SceneBuilders.makeWorld(device: device, region: try region ?? WorldRectangle(min: [-50, -50], max: [50, 50]))
        renderer = try BubblePhysicsMetalRender(device: device, assets: XCTUnwrap(world.assets))
        harness = try OffscreenRenderHarness(device: device)
    }

    /// Fizyka i render materiałów w pierwszych transakcjach: baza budowniczych plus podane materiały renderu.
    func submitMaterials(_ materials: [(RenderMaterialID, RenderMaterial)]) throws {
        var transaction = try SceneBuilders.baseTransaction()
        for (id, material) in materials { transaction = transaction.updateRenderMaterial(id, material: material) }
        world.submit(transaction)
    }

    @discardableResult
    func step() async -> WorldFrame { await world.advance(by: SceneBuilders.step) }

    func render(viewport: Viewport? = nil) async throws {
        try await harness.render(world: world, renderer: renderer, viewport: viewport ?? Self.viewport)
    }

    func assertPixel(_ point: WorldPoint, _ expected: RGBA, _ message: String = "", viewport: Viewport? = nil,
                     file: StaticString = #filePath, line: UInt = #line) {
        harness.assertPixel(point, viewport ?? Self.viewport, expected, message, file: file, line: line)
    }
}
