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

    func testPolygonRenderPassesMetalValidation() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        process.arguments = ["-XCTest",
            "BubblePhysicsMetalRenderTests.MetalRenderIntegrationTests/testStyledPolygonInvokesCustomPipelineAndDrawsItsGeometry",
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
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertEqual(world.diagnostics.lastRejectionReason, .frameEncoding)
        XCTAssertNil(world.diagnostics.failureReason, "błąd gry nie kończy świata")
    }

    private typealias B = SceneBuilders

    /// Bańka z zainteresowaniem kontaktem na statycznej podłodze pod grawitacją; styk zaczyna się w ciągu kilkudziesięciu kroków.
    private func settlingWorld(device: MTLDevice) throws -> BubbleWorld {
        let world = try B.makeWorld(device: device, gravity: [0, -400])
        world.submit(try B.baseTransaction().add(B.box(100, at: [300, 5], half: [300, 5]))
            .add(B.bubble(1, at: [150, 18.3], interest: .contact)))
        return world
    }

    /// Krok z buforem aplikacji; `closure` nie wypisuje nic do bufora, bo solver koduje do niego tylko obliczenia.
    private func advance(_ world: BubbleWorld, _ queue: MTLCommandQueue,
                         _ closure: @escaping () throws -> Void = {}) async throws -> (WorldFrame, MTLCommandBuffer) {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        return (await world.advance(by: B.step, commandBuffer: command, encodeRender: closure), command)
    }

    // P-B-58, G9-AC2: klatka odrzucona przez rzucające domknięcie nic nie zmienia w stanie świata ani steppera, więc
    // ponowienie daje dokładnie te same klatki i zdarzenia co świat bliźniaczy bez odrzuceń. Ścieżka z krokiem GPU.
    func testRejectedFrameRetryGivesSameEvents() async throws {
        struct GameError: Error {}
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let clean = try settlingWorld(device: device), retried = try settlingWorld(device: device)
        var cleanEvents: [WorldEvent] = [], retriedEvents: [WorldEvent] = []
        for index in 0..<45 {
            let (expected, _) = try await advance(clean, queue)
            let previous = retried.diagnostics
            let (rejected, command) = try await advance(retried, queue) { throw GameError() }
            XCTAssertEqual(command.status, .notEnqueued, "krok \(index)")
            XCTAssertEqual(rejected.stepIndex, UInt64(index), "odrzucona klatka zostawia poprzednią")
            XCTAssertEqual(retried.diagnostics.lastAdvanceIssue, .frameRejected)
            XCTAssertEqual(retried.diagnostics.pendingTransactionCount, previous.pendingTransactionCount)
            let (actual, _) = try await advance(retried, queue)
            XCTAssertEqual(actual.stepIndex, expected.stepIndex)
            XCTAssertEqual(actual.events, expected.events, "krok \(index): ponowienie daje te same zdarzenia")
            XCTAssertEqual(actual.objects, expected.objects, "krok \(index)")
            cleanEvents += expected.events; retriedEvents += actual.events
        }
        XCTAssertEqual(retriedEvents, cleanEvents)
        XCTAssertEqual(B.began(cleanEvents).count, 1, "scena ma dać contactBegan, inaczej test nic nie dowodzi")
        XCTAssertNil(retried.diagnostics.failureReason)
    }

    // P-B-58: to samo w gałęzi bez kroku GPU: po usunięciu obu ciał kolejny krok nie ma masy, więc solver nie biegnie, a
    // render kodowany jest w świecie. Odrzucona klatka nie zmienia historii kontaktów steppera.
    func testRejectedFrameRetryWithoutGPUStepGivesSameEvents() async throws {
        struct GameError: Error {}
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let clean = try settlingWorld(device: device), retried = try settlingWorld(device: device)
        for world in [clean, retried] {
            for _ in 0..<45 { _ = try await advance(world, queue) }
            world.submit(WorldTransaction().remove(ObjectID(rawValue: 1)).remove(ObjectID(rawValue: 100)))
        }
        let (expected, _) = try await advance(clean, queue)
        let (rejected, command) = try await advance(retried, queue) { throw GameError() }
        XCTAssertEqual(command.status, .notEnqueued)
        XCTAssertEqual(rejected.stepIndex, 45)
        XCTAssertEqual(retried.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertEqual(retried.diagnostics.pendingTransactionCount, 1)
        let (actual, retry) = try await advance(retried, queue)
        XCTAssertEqual(retry.status, .completed)
        XCTAssertEqual(actual.stepIndex, 46)
        XCTAssertEqual(actual.events, expected.events)
        XCTAssertEqual(actual.objects, expected.objects)
        XCTAssertTrue(actual.objects.isEmpty)
        XCTAssertNil(retried.diagnostics.failureReason)
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

    func testRigidBodyIsDrawnByTechnicalPipeline() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60), device: device)
        world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 2), material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(.init(rawValue: 2), material: try RenderMaterial())
            .add(.rigidBody(try RigidBodyDescriptor(id: .init(rawValue: 2),
                vertices: [[-1,-1], [1,-1], [1,1], [-1,1]],
                physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 2)))))
        _ = await world.advance(by: 1.0 / 60)
        let renderer = try BubblePhysicsMetalRender(device: device)
        let harness = try OffscreenRenderHarness(device: device)
        try await harness.render(world: world, renderer: renderer, viewport: Viewport(center: .zero, size: [4,4]))
        XCTAssertNotEqual(Array(harness.pixel(x: 128, y: 128).prefix(3)), [0, 0, 0])
        XCTAssertEqual(Array(harness.pixel(x: 8, y: 8).prefix(3)), [0, 0, 0])
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
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(try BubbleDescriptor(id: .init(rawValue: 1), position: [3,0],
                targetRadius: 0.5, physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)))))
        let renderer = try BubblePhysicsMetalRender(device: device)
        let harness = try OffscreenRenderHarness(device: device)
        let command = try harness.makeCommandBuffer()
        let pass = harness.makePass()
        let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
            try renderer.encode(world: world, viewport: Viewport(center: [3,0], size: [4,4]),
                                commandBuffer: command, renderPassDescriptor: pass)
        }
        XCTAssertEqual(frame.stepIndex, 1)
        XCTAssertEqual(Array(harness.pixel(x: 128, y: 128).prefix(3)), [0,0,0])
    }

    func testPublicStressHarnessExercisesSameBufferWithoutContourReadback() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var progress: [Int] = []
        let report = try await PublicWorldStressBenchmark.run(device: device,
            warmupFrames: 1, measuredFrames: 2) { completed, _ in
                progress.append(completed)
            }
        XCTAssertEqual(report.solverIterationLimit, 4)
        XCTAssertEqual(report.warmupFrames, 1)
        XCTAssertEqual(report.measuredFrames, 2)
        XCTAssertEqual(report.contourCPUReadbacks, 0)
        XCTAssertEqual(report.failedFrames, 0)
        XCTAssertTrue(report.p95Milliseconds.isFinite)
        XCTAssertTrue(report.safetyPassed)
        XCTAssertTrue(report.text.contains("gpu_p95_ms="))
        XCTAssertTrue(report.text.contains("host_encoding_p95_ms="))
        XCTAssertTrue(report.text.contains("host_waiting_p95_ms="))
        XCTAssertEqual(progress, [1, 2, 3])
    }

    private func makeWorld(device: MTLDevice) throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-10, -10], max: [10, 10]),
            fixedTimeStep: 1.0 / 60), device: device)
        world.submit(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: try PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(try BubbleDescriptor(id: .init(rawValue: 1), position: .zero,
                targetRadius: 1, physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)))))
        return world
    }
}
