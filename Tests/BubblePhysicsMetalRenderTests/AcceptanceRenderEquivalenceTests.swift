import BubblePhysics
import BubblePhysicsMetalRender
import BubblePhysicsMetalRenderBenchmark
import CoreGraphics
import Metal
import XCTest

/// Równoważność optymalizacji renderu etapu 9 (P-B-86, G12-AC4): scena akceptacyjna po 120 krokach, narysowana w 1125×2436
/// jak w benchmarku, daje piksele celu renderu równe wzorcowi zapisanemu przed pierwszą zmianą renderu. Optymalizacja,
/// która zmienia choć jeden piksel, jest zmianą obrazu i ma tu zawieść.
///
/// Wzorzec pochodzi z Apple M1 Pro (jedyne urządzenie wzorca); na innym test wzorca jest pomijany z powodem, bo GPU innej
/// rodziny może legalnie rasteryzować i mieszać inaczej. Kroki i scena są te same co w `AcceptanceEquivalenceTests`.
@MainActor
final class AcceptanceRenderEquivalenceTests: XCTestCase {
    private typealias Scene = PublicWorldStressBenchmark.Scene

    /// Urządzenie, na którym zapisano wzorzec.
    private static let referenceDeviceName = "Apple M1 Pro"
    private static let referenceSteps = 120
    private static let referenceWidth = 1125, referenceHeight = 2436
    /// Wzorzec policzony od nowa na silniku 4.0.0 (prawo kontaktu K_c w podkrokach, Apple M1 Pro, ta scena i kroki). Hash z silnika 3.x
    /// (`0xc947960553219dd3`, poprawka 3.0.1) nie ma już sensu: spec. 4 zmienia fizykę kontaktu, więc bańki stoją gdzie indziej,
    /// a scena kładzie 287 baniek zamiast 300. Wzorzec pilnuje tylko tego, że zmiana renderu nie zmienia ani piksela obrazu silnika 4.0.0.
    private static let referenceCommit = "silnik 4.0.0 (feature/engine-4-0-0)"
    private static let referencePixelHash: UInt64 = 0x7107d3404a48d192
    private struct RenderedImage {
        let width: Int
        let height: Int
        let pixels: [UInt8]
        /// FNV-1a po bajtach obrazu (BGRA, wiersz po wierszu od góry).
        var hash: UInt64 {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in pixels { hash = (hash ^ UInt64(byte)) &* 0x100_0000_01B3 }
            return hash
        }
    }

    /// Te same kroki i ten sam render co benchmark: transakcja kroku, `advance` o 1/60 s z `encodeRender` w buforze aplikacji,
    /// kamera pokrywająca region sceny, cel `bgra8Unorm` czyszczony do czerni w każdej klatce. Zwraca cel po ostatnim kroku.
    private func render(steps: Int, device: MTLDevice) async throws -> RenderedImage {
        let scene = Scene.acceptance
        let width = Self.referenceWidth, height = Self.referenceHeight
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try scene.configuration(), device: device)
        let assets = try XCTUnwrap(world.assets)
        let renderer = try BubblePhysicsMetalRender(device: device, assets: assets)
        world.submit(try scene.initialTransaction(assets: assets))
        let regionHeight = Stress300Scene.regionHeight(bubbleCount: Stress300Scene.defaultBubbleCount)
        let aspect = Float(width) / Float(height)
        let viewWidth = max(375, regionHeight * aspect)
        let viewport = try Viewport(center: [187.5, regionHeight / 2], size: [viewWidth, viewWidth / aspect])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height,
                                                                   mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(device.makeCommandQueue())
        for index in 0..<steps {
            if let transaction = try scene.stepTransaction(step: index) { world.submit(transaction) }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            _ = await world.advance(by: 1.0 / 60, commandBuffer: command) {
                try renderer.encode(world: world, viewport: viewport, commandBuffer: command, renderPassDescriptor: pass)
            }
            XCTAssertEqual(command.status, .completed, "krok \(index + 1)")
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, "krok \(index + 1)")
        }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        target.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        return RenderedImage(width: width, height: height, pixels: pixels)
    }

    private func nonBlackPixelCount(_ image: RenderedImage) -> Int {
        var count = 0
        for index in stride(from: 0, to: image.pixels.count, by: 4)
        where image.pixels[index] != 0 || image.pixels[index + 1] != 0 || image.pixels[index + 2] != 0 { count += 1 }
        return count
    }

    func testAcceptanceSceneRenderedAfter120StepsEqualsTheReferencePixels() async throws {
        try await assertRenderMatchesReference()
    }

    private func assertRenderMatchesReference() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        try XCTSkipUnless(device.name == Self.referenceDeviceName,
            "wzorzec pochodzi z \(Self.referenceDeviceName), a to jest \(device.name)")
        let expected = Self.referencePixelHash
        let image = try await render(steps: Self.referenceSteps, device: device)
        XCTAssertEqual(image.width, Self.referenceWidth)
        XCTAssertEqual(image.height, Self.referenceHeight)
        // Wzorzec ma coś pokazywać: obraz nie jest pustym czyszczeniem ani samym tłem.
        let drawn = nonBlackPixelCount(image)
        XCTAssertGreaterThan(drawn, image.width * image.height / 20, "scena zajmuje co najmniej 5% pikseli")
        let origin = "wzorzec: \(Self.referenceDeviceName), \(Self.referenceSteps) kroków, \(Self.referenceWidth)×\(Self.referenceHeight), commit \(Self.referenceCommit)"
        XCTAssertEqual(String(image.hash, radix: 16), String(expected, radix: 16),
            "piksele sceny akceptacyjnej różnią się od wzorca sprzed zmian renderu (\(origin))")
    }

    /// Sam wzorzec nic nie znaczy, gdy hash jest stały albo render nie jest powtarzalny: scena się rusza, hash to widzi,
    /// a dwa przebiegi na tym samym urządzeniu są identyczne (podstawa porównania z wzorcem).
    func testHashSeesTheSceneMoveAndTwoRunsAreIdentical() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let early = try await render(steps: 1, device: device)
        let first = try await render(steps: Self.referenceSteps, device: device)
        let second = try await render(steps: Self.referenceSteps, device: device)
        XCTAssertNotEqual(early.hash, first.hash)
        XCTAssertEqual(first.hash, second.hash, "piksele różnią się między przebiegami")
    }
}
