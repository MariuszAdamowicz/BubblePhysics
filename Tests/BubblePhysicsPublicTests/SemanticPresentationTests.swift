import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

@MainActor
final class SemanticPresentationTests: XCTestCase {
    func testEngineSemanticRendererUsesDistinctPaletteForBaseRoundValues() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let values = [2, 3, 5, 7]
        var colors: [[UInt8]] = []
        for value in values {
            let world = try makeWorld(device: device, bubbleIDs: [1])
            world.submit(WorldTransaction().setBubblePresentation(.init(rawValue: 1),
                presentation: try BubblePresentation(value: value, isGrabbed: false)))
            colors.append(try await render(world, device: device, sampleX: 20).pixel)
        }

        XCTAssertEqual(Set(colors).count, values.count, "Bazowe wartości rundy muszą mieć rozróżnialne kolory silnika")
    }

    func testEngineSemanticRendererMakesOneAndThreeDigitValuesLegible() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let oneDigit = try await renderedPixels(value: 8, device: device)
        let threeDigits = try await renderedPixels(value: 128, device: device)

        let oneInk = inkBounds(in: oneDigit)
        let threeInk = inkBounds(in: threeDigits)
        XCTAssertGreaterThan(oneInk.count, 30, "Jednocyfrowa wartość musi mieć widoczny kontrastowy glif")
        XCTAssertGreaterThan(threeInk.count, oneInk.count, "Wielocyfrowa wartość musi renderować wszystkie cyfry")
        XCTAssertGreaterThan(threeInk.width, oneInk.width, "Wielocyfrowy glif musi zajmować więcej szerokości niż jedna cyfra")
    }

    func testRejectsInvalidValueAndPublishesOnlyAcceptedPresentation() async throws {
        XCTAssertThrowsError(try BubblePresentation(value: 0, isGrabbed: false))

        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60),
            device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let id = ObjectID(rawValue: 1)
        let initial = world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: try RenderStyle())
            .add(.bubble(try BubbleDescriptor(id: id, position: .zero, targetRadius: 1,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1)))))
        let accepted = world.submit(WorldTransaction().setBubblePresentation(id,
            presentation: try BubblePresentation(value: 2, isGrabbed: true)))

        let frame = await world.advance(by: 1.0 / 60)

        XCTAssertEqual(frame.transactionReceipts.map(\.token), [initial, accepted])
        XCTAssertEqual(WorldTransaction().setBubblePresentation(id,
            presentation: try BubblePresentation(value: 2, isGrabbed: true)).operations,
            [.setBubblePresentation(id, try BubblePresentation(value: 2, isGrabbed: true))])
    }

    func testExistingBubbleConstructorAndMergeResultRemainCompatible() throws {
        let descriptor = try BubbleDescriptor(id: .init(rawValue: 1), position: .zero, targetRadius: 1,
            physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))
        XCTAssertEqual(descriptor.id, .init(rawValue: 1))

        let result = BubbleResult(id: .init(rawValue: 3), physicsMaterialID: .init(rawValue: 1),
            renderStyleID: .init(rawValue: 1), bubblePresentation: try BubblePresentation(value: 4, isGrabbed: false))
        XCTAssertEqual(result.bubblePresentation, try BubblePresentation(value: 4, isGrabbed: false))
    }

    func testMergePresentationIsVisibleWithItsFirstReceiptAndRejectionPreservesIt() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device, bubbleIDs: [1, 2])
        _ = await world.advance(by: 1.0 / 60)
        let merge = world.submit(WorldTransaction().mergeBubbles([.init(rawValue: 1), .init(rawValue: 2)],
            result: BubbleResult(id: .init(rawValue: 3), physicsMaterialID: .init(rawValue: 1),
                renderStyleID: .init(rawValue: 1), bubblePresentation: try BubblePresentation(value: 8, isGrabbed: true))))

        let merged = try await render(world, device: device)
        XCTAssertEqual(merged.frame.transactionReceipts.map(\.token), [merge])
        XCTAssertNotEqual(merged.pixel, [0, 0, 0, 255], "Rezultat merge musi być widoczny w pierwszej opublikowanej klatce z receipt")

        let rejected = world.submit(WorldTransaction().setBubblePresentation(.init(rawValue: 999),
            presentation: try BubblePresentation(value: 9, isGrabbed: false)))
        let afterRejection = try await render(world, device: device)
        XCTAssertTrue(afterRejection.frame.events.contains { event in
            if case .transactionRejected(let token, _) = event { return token == rejected }
            return false
        })
        XCTAssertEqual(afterRejection.pixel, merged.pixel, "Odrzucona transakcja nie może zmienić opublikowanej prezentacji")
    }

    private func makeWorld(device: MTLDevice, bubbleIDs: [UInt64]) throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60), device: device)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: try RenderStyle())
        for rawValue in bubbleIDs {
            transaction = transaction.add(.bubble(try BubbleDescriptor(id: .init(rawValue: rawValue),
                position: .zero, targetRadius: 1, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        }
        world.submit(transaction)
        return world
    }

    private func render(_ world: BubbleWorld, device: MTLDevice, sampleX: Int = 32) async throws -> (frame: WorldFrame, pixel: [UInt8]) {
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let renderer = try BubblePhysicsMetalRender(device: device)
        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4, 4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(sampleX, 32, 1, 1), mipmapLevel: 0)
        return (frame, pixel)
    }

    private func renderedPixels(value: Int, device: MTLDevice) async throws -> [[UInt8]] {
        let world = try makeWorld(device: device, bubbleIDs: [1])
        world.submit(WorldTransaction().setBubblePresentation(.init(rawValue: 1),
            presentation: try BubblePresentation(value: value, isGrabbed: false)))
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let renderer = try BubblePhysicsMetalRender(device: device)
        _ = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4, 4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }
        var bytes = [UInt8](repeating: 0, count: 64 * 64 * 4)
        texture.getBytes(&bytes, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
        return stride(from: 0, to: bytes.count, by: 4).map { Array(bytes[$0..<$0 + 4]) }
    }

    private func inkBounds(in pixels: [[UInt8]]) -> (count: Int, width: Int) {
        let locations = pixels.enumerated().compactMap { offset, pixel -> Int? in
            pixel == [255, 255, 255, 255] ? offset : nil
        }
        let columns = locations.map { $0 % 64 }
        return (locations.count, (columns.max() ?? 0) - (columns.min() ?? 0) + 1)
    }

    private func textureDescriptor() -> MTLTextureDescriptor {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return descriptor
    }
}
