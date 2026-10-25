import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

@MainActor
final class SemanticPresentationRenderTests: XCTestCase {
    func testValueAndGrabAreEncodedWithDeformedBubbleInCallerCommandBuffer() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60), device: device)
        let id = ObjectID(rawValue: 1)
        world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: try RenderStyle())
            .add(.bubble(try BubbleDescriptor(id: id, position: .zero, targetRadius: 1,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
            .setBubblePresentation(id, presentation: try BubblePresentation(value: 16, isGrabbed: true)))
        let renderer = try BubblePhysicsMetalRender(device: device)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: 64, height: 64, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            return descriptor
        }()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())

        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4, 4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }

        XCTAssertEqual(frame.transactionReceipts.count, 1)
        XCTAssertEqual(command.status, .completed)
        var center = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&center, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        XCTAssertEqual(center[3], 255, "Silnikowa prezentacja musi zostać zakodowana w masce bańki")
    }

    func testDistinctValuesAndGrabStateProduceDistinctEngineRenderingOverBubbleFill() async throws {
        let ungrabbedOne = try await renderedPixel(value: 1, isGrabbed: false)
        let ungrabbedEight = try await renderedPixel(value: 8, isGrabbed: false)
        let grabbedOne = try await renderedPixel(value: 1, isGrabbed: true)

        XCTAssertNotEqual(ungrabbedOne, [0, 0, 0, 255], "Wypełnienie bańki musi istnieć pod prezentacją")
        XCTAssertNotEqual(ungrabbedOne, ungrabbedEight, "Różne wartości nie mogą kolidować w renderingu silnika")
        XCTAssertNotEqual(ungrabbedOne, grabbedOne, "Stan chwytu musi być widoczny w renderingu silnika")
    }

    private func renderedPixel(value: Int, isGrabbed: Bool) async throws -> [UInt8] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60), device: device)
        let id = ObjectID(rawValue: 1)
        world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: try RenderStyle())
            .add(.bubble(try BubbleDescriptor(id: id, position: .zero, targetRadius: 1,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
            .setBubblePresentation(id, presentation: try BubblePresentation(value: value, isGrabbed: isGrabbed)))
        let texture = try XCTUnwrap(device.makeTexture(descriptor: {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: 64, height: 64, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            return descriptor
        }()))
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
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        return pixel
    }
}
