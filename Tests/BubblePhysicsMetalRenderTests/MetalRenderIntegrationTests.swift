import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest

@MainActor
final class MetalRenderIntegrationTests: XCTestCase {
#if os(macOS)
    func testBubbleRenderPassesMetalValidation() throws {
        // Walidacja Metal musi być włączona przed utworzeniem MTLDevice;
        // dlatego uruchamiamy prawdziwy test renderera w nowym procesie.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest",
            "BubblePhysicsMetalRenderTests.MetalRenderIntegrationTests/testRendererAcceptsViewportAndCallerCommandBuffer",
            Bundle(for: MetalRenderIntegrationTests.self).bundlePath]
        var environment = ProcessInfo.processInfo.environment
        environment["MTL_DEBUG_LAYER"] = "1"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        process.waitUntilExit()
        let diagnostic = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, diagnostic)
    }
#endif

    func testRendererAcceptsViewportAndCallerCommandBuffer() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        let frame = await world.advance(by: 1.0 / 60)
        XCTAssertEqual(frame.stepIndex, 1)
        let texture = try XCTUnwrap(device.makeTexture(descriptor: {
            let value = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
                width: 64, height: 64, mipmapped: false)
            value.usage = [.renderTarget, .shaderRead]
            value.storageMode = .shared
            return value
        }()))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let renderer = try BubblePhysicsMetalRender(device: device)
        try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4, 4]),
                            commandBuffer: command, renderPassDescriptor: pass)
        XCTAssertEqual(command.status, .notEnqueued)
        command.commit()
        await command.completed()
        XCTAssertEqual(command.status, .completed)
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        XCTAssertNotEqual(Array(pixel.prefix(3)), [0, 0, 0])
    }

    func testCustomPipelineReceivesResolvedStyleChannels() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let channel = ParameterID(rawValue: "intensity")
        let world = try makeWorld(device: device, style: RenderStyle(shader: .custom("game"),
            channels: [channel: 0.4]), local: PresentationParameters(channels: [channel: 0.8]))
        _ = await world.advance(by: 1.0 / 60)
        let renderer = try BubblePhysicsMetalRender(device: device)
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        struct V { float4 position [[position]]; float2 worldPosition; };
        fragment float4 customColor(V in [[stage_in]], constant float &level [[buffer(0)]]) {
            return float4(0, level, 0, 1);
        }
        """
        let library = try await device.makeLibrary(source: source, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = renderer.makeContourVertexFunction()
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "customColor"))
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try await device.makeRenderPipelineState(descriptor: descriptor)
        var received: Float = -1
        renderer.customPipelines["game"] = RenderStylePipeline(state: pipeline) { encoder, channels in
            received = channels[channel] ?? -1
            var value = received
            encoder.setFragmentBytes(&value, length: MemoryLayout<Float>.stride, index: 0)
        }
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 64, height: 64, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4, 4]),
                            commandBuffer: command, renderPassDescriptor: pass)
        command.commit()
        await command.completed()
        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(received, 0.8, accuracy: 0.0001)
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        XCTAssertGreaterThan(pixel[1], 180)
    }

    func testPhysicsAndRendererEncodeIntoCallerCommandBufferBeforePublication() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        let renderer = try BubblePhysicsMetalRender(device: device)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 64, height: 64, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        var statusAtRender: MTLCommandBufferStatus?
        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            statusAtRender = command.status
            try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4, 4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }
        XCTAssertEqual(statusAtRender, .notEnqueued)
        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(frame.stepIndex, 1)
        var pixel = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&pixel, bytesPerRow: 4, from: MTLRegionMake2D(32, 32, 1, 1), mipmapLevel: 0)
        XCTAssertNotEqual(Array(pixel.prefix(3)), [0, 0, 0])
    }

    func testFailedRenderKeepsPreviousPublishedWorldFrame() async throws {
        struct RenderFailure: Error {}
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        let first = await world.advance(by: 1.0 / 60)
        let previousContour = world.debugContourSnapshot()
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let result = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            throw RenderFailure()
        }
        XCTAssertEqual(result, first)
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertEqual(world.debugContourSnapshot(), previousContour)
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed)
    }

    func testEmptyWorldAlsoCompletesCallerCommandBuffer() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]),
            fixedTimeStep: 1.0 / 60), device: device)
        let renderer = try BubblePhysicsMetalRender(device: device)
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 16, height: 16, mipmapped: false)
        textureDescriptor.usage = .renderTarget
        let texture = try XCTUnwrap(device.makeTexture(descriptor: textureDescriptor))
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4, 4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertEqual(command.status, .completed)
    }

    func testStyledPolygonInvokesCustomPipelineAndDrawsItsGeometry() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60), device: device)
        let channel = ParameterID(rawValue: "level")
        world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 2), material: try PhysicsMaterial(kind: .polygon))
            .updateRenderStyle(.init(rawValue: 2), style: try RenderStyle(shader: .custom("polygon"), channels: [channel: 0.6]))
            .add(.polygon(try PolygonDescriptor(id: .init(rawValue: 2),
                vertices: [[-1,-1], [1,-1], [1,1], [-1,1]],
                physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 2)))))
        _ = await world.advance(by: 1.0 / 60)
        let renderer = try BubblePhysicsMetalRender(device: device)
        let library = try await device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 position [[position]]; float2 worldPosition; };
            fragment float4 color(V in [[stage_in]]) { return float4(0, 1, 0, 1); }
            """, options: nil)
        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = renderer.makeContourVertexFunction()
        pipelineDescriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "color"))
        pipelineDescriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try await device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        var received: Float = -1
        renderer.customPipelines["polygon"] = RenderStylePipeline(state: pipeline) { _, channels in
            received = channels[channel] ?? -1
        }
        let texture = try makeTexture(device: device)
        let pass = makePass(texture: texture)
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4,4]),
                            commandBuffer: command, renderPassDescriptor: pass)
        command.commit()
        await command.completed()
        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(received, 0.6, accuracy: 0.001)
        XCTAssertGreaterThan(pixel(texture, x: 32, y: 32)[1], 200)
    }

    func testSameBufferRenderReceivesPreparedTransitionChannel() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let channel = ParameterID(rawValue: "level")
        let world = try makeWorld(device: device, style: RenderStyle(shader: .custom("transition"),
            channels: [channel: 0]))
        world.submit(WorldTransaction().startTransition(.init(
            target: .renderStyle(.init(rawValue: 1), channel), value: .scalar(1), duration: 1)))
        let renderer = try BubblePhysicsMetalRender(device: device)
        let library = try await device.makeLibrary(source: """
            #include <metal_stdlib>
            using namespace metal;
            struct V { float4 position [[position]]; float2 worldPosition; };
            fragment float4 color(V in [[stage_in]]) { return float4(1); }
            """, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = renderer.makeContourVertexFunction()
        descriptor.fragmentFunction = try XCTUnwrap(library.makeFunction(name: "color"))
        descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
        let pipeline = try await device.makeRenderPipelineState(descriptor: descriptor)
        var received: Float = -1
        renderer.customPipelines["transition"] = RenderStylePipeline(state: pipeline) { _, channels in
            received = channels[channel] ?? -1
        }
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let pass = makePass(texture: try makeTexture(device: device))
        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4,4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertEqual(received, 1.0 / 60.0, accuracy: 0.002)
    }

    func testLastBodyRemovalClearsDebugContourSnapshot() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(device: device)
        _ = await world.advance(by: 1.0 / 60)
        XCTAssertFalse(world.debugContourSnapshot().isEmpty)
        world.submit(WorldTransaction().remove(.init(rawValue: 1)))
        let frame = await world.advance(by: 1.0 / 60)
        XCTAssertEqual(frame.stepIndex, 2)
        XCTAssertTrue(world.debugContourSnapshot().isEmpty)
    }

    func testRegionRemovedBubbleIsNotDrawnInItsRemovalFrame() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-2,-2], max: [2,2]), fixedTimeStep: 1.0 / 60), device: device)
        world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: try RenderStyle())
            .add(.bubble(try BubbleDescriptor(id: .init(rawValue: 1), position: [3,0],
                targetRadius: 0.5, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1)))))
        let renderer = try BubblePhysicsMetalRender(device: device)
        let texture = try makeTexture(device: device)
        let pass = makePass(texture: texture)
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: [3,0], size: [4,4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertEqual(Array(pixel(texture, x: 32, y: 32).prefix(3)), [0,0,0])
    }

    func testSensorAndForceFieldStylesAreRenderedWithoutBodies() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10,-10], max: [10,10]), fixedTimeStep: 1.0 / 60), device: device)
        let styleID = RenderStyleID(rawValue: 1)
        world.submit(WorldTransaction()
            .updateRenderStyle(styleID, style: try RenderStyle())
            .add(.sensor(try SensorDescriptor(id: .init(rawValue: 1), position: [-1,0],
                geometry: RangeGeometry.circle(radius: 0.5), renderStyleID: styleID)))
            .add(.forceField(try ForceFieldDescriptor(id: .init(rawValue: 2), position: [1,0],
                geometry: RangeGeometry.circle(radius: 0.5), field: .directional(force: .zero),
                renderStyleID: styleID))))
        let renderer = try BubblePhysicsMetalRender(device: device)
        let texture = try makeTexture(device: device)
        let pass = makePass(texture: texture)
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: .zero, size: [4,4]),
                commandBuffer: command, renderPassDescriptor: pass)
        }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertGreaterThan(pixel(texture, x: 16, y: 32)[1], 100)
        XCTAssertGreaterThan(pixel(texture, x: 48, y: 32)[1], 100)
    }

    func testPublicStressHarnessExercisesSameBufferWithoutContourReadback() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let report = try await PublicWorldStressBenchmark.run(device: device,
            warmupFrames: 1, measuredFrames: 2) { _, _ in }
        XCTAssertEqual(report.solverIterationLimit, 4)
        XCTAssertEqual(report.warmupFrames, 1)
        XCTAssertEqual(report.measuredFrames, 2)
        XCTAssertEqual(report.contourCPUReadbacks, 0)
        XCTAssertEqual(report.failedFrames, 0)
        XCTAssertTrue(report.p95Milliseconds.isFinite)
    }

    private func makeTexture(device: MTLDevice) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm,
            width: 64, height: 64, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        return try XCTUnwrap(device.makeTexture(descriptor: descriptor))
    }

    private func makePass(texture: MTLTexture) -> MTLRenderPassDescriptor {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        return pass
    }

    private func pixel(_ texture: MTLTexture, x: Int, y: Int) -> [UInt8] {
        var result = [UInt8](repeating: 0, count: 4)
        texture.getBytes(&result, bytesPerRow: 4, from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        return result
    }

    private func makeWorld(device: MTLDevice, style: RenderStyle = try! RenderStyle(),
                           local: PresentationParameters = .empty) throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]),
            fixedTimeStep: 1.0 / 60), device: device)
        world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: style)
            .add(.bubble(try BubbleDescriptor(id: .init(rawValue: 1), position: .zero,
                targetRadius: 1, physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1),
                presentation: local))))
        return world
    }
}
