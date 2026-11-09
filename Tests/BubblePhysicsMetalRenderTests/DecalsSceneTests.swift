import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import Metal
import XCTest

/// P-B-76: scena `decals` strażnika to stress-300 z teksturą przyklejoną w materiale i naklejką tekstową na każdej bańce,
/// a render w pomiarze naprawdę rysuje te naklejki.
@MainActor
final class DecalsSceneTests: XCTestCase {
    private func makeWorld(_ scene: PublicWorldStressBenchmark.Scene) throws -> (BubbleWorld, AssetRegistry, MTLDevice) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: scene.configuration(), device: device, solverIterationLimit: 4)
        return (world, try XCTUnwrap(world.assets), device)
    }

    func testEveryBubbleHasATextDecalAndTheMaterialHasAnAttachedTexture() throws {
        let (_, assets, _) = try makeWorld(.decals)
        let operations = try PublicWorldStressBenchmark.Scene.decals.initialTransaction(assets: assets).operations
        var bubbles = 0
        var materials: [RenderMaterial] = []
        for operation in operations {
            switch operation {
            case .add(.bubble(let bubble)):
                bubbles += 1
                guard case .text(let text, let source)? = bubble.decal?.content else {
                    XCTFail("bańka \(bubble.id) bez naklejki tekstowej"); continue
                }
                XCTAssertFalse(text.isEmpty)
                XCTAssertTrue(assets.contains(source), "źródło glifów naklejki jest w rejestrze")
                for character in text { XCTAssertNotNil(assets.glyph(character, in: source), "znak \(character) w zestawie") }
            case .updateRenderMaterial(_, let material): materials.append(material)
            default: break
            }
        }
        XCTAssertEqual(bubbles, 300)
        let material = try XCTUnwrap(materials.first { $0.texture != nil }, "materiał z teksturą")
        XCTAssertEqual(material.bubbleMapping, .attached)
        XCTAssertTrue(try assets.contains(XCTUnwrap(material.texture)))
        // Stress-300 bez naklejek nie ma żadnej.
        let plain = try PublicWorldStressBenchmark.Scene.stress300.initialTransaction(assets: assets).operations
        XCTAssertFalse(plain.contains { if case .add(.bubble(let bubble)) = $0 { return bubble.decal != nil }; return false })
    }

    /// Liczba wywołań rysowania po kilku krokach: scena `decals` dokłada ciągi naklejek do tych samych baniek i bryl.
    private func drawCalls(_ scene: PublicWorldStressBenchmark.Scene) async throws -> Int {
        let (world, assets, device) = try makeWorld(scene)
        let renderer = try BubblePhysicsMetalRender(device: device, assets: assets)
        world.submit(try scene.initialTransaction(assets: assets))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 375, height: 700, mipmapped: false)
        descriptor.usage = .renderTarget
        let target = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var calls = 0
        for _ in 0..<3 {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            _ = await world.advance(by: 1.0 / 60, commandBuffer: command) {
                try renderer.encode(world: world, viewport: Viewport(center: [187.5, 350], size: [375, 700]),
                                    commandBuffer: command, renderPassDescriptor: pass)
            }
            XCTAssertEqual(command.status, .completed)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
            calls = renderer.lastDrawCallCount
        }
        return calls
    }

    func testDecalsSceneDrawsDecalRunsOnTopOfTheBubbles() async throws {
        let plain = try await drawCalls(.stress300)
        let decorated = try await drawCalls(.decals)
        XCTAssertGreaterThan(decorated, plain, "naklejki dokładają ciągi rysowania (\(decorated) wobec \(plain))")
    }

    func testDecalsMeasurementIsSafe() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: .decals, warmupFrames: 2, measuredFrames: 8,
                                                              progress: { _, _ in })
        XCTAssertEqual(report.scene, "decals")
        XCTAssertTrue(report.safetyPassed)
        XCTAssertEqual(report.measuredFrames, 8)
    }
}
