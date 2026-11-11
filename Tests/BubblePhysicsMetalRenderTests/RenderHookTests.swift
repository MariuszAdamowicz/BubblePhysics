import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-54 (G9-AC1): gra rysuje w passie świata przez punkty zaczepienia. Prostokąty gry malują zwykłym potokiem z
/// własnego źródła shadera, więc test sprawdza też, że renderer po haku wiąże swoje bufory od nowa.
@MainActor
final class RenderHookTests: XCTestCase {
    private typealias B = SceneBuilders
    private let red = RGBA(1, 0, 0, 1), blue = RGBA(0, 0, 1, 1), green = RGBA(0, 1, 0, 1),
                yellow = RGBA(1, 1, 0, 1), magenta = RGBA(1, 0, 1, 1), black = RGBA(0, 0, 0, 1)
    private let redID = RenderMaterialID(rawValue: 10), blueID = RenderMaterialID(rawValue: 12)
    private let ghost = RenderTestScene.ghost

    private struct HookError: Error {}

    /// Maluje prostokąt we współrzędnych świata jednym kolorem; macierz z haka zamienia świat na clip.
    private final class Painter {
        private let pipeline: MTLRenderPipelineState
        init(device: MTLDevice) throws {
            let source = """
            #include <metal_stdlib>
            using namespace metal;
            vertex float4 hookVertex(uint id [[vertex_id]], constant float2 *points [[buffer(0)]],
                                     constant float4x4 &matrix [[buffer(1)]]) {
                return matrix * float4(points[id], 0, 1);
            }
            fragment float4 hookFragment(constant float4 &color [[buffer(0)]]) { return color; }
            """
            let library = try device.makeLibrary(source: source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "hookVertex")
            descriptor.fragmentFunction = library.makeFunction(name: "hookFragment")
            descriptor.colorAttachments[0].pixelFormat = .rgba8Unorm
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        }

        func hook(min: WorldPoint, max: WorldPoint, color: RGBA) -> RenderHooks.Hook {
            { encoder, matrix in
                var matrix = matrix
                var color = SIMD4<Float>(color.red, color.green, color.blue, color.alpha)
                let points: [SIMD2<Float>] = [[min.x, min.y], [max.x, min.y], [max.x, max.y],
                                              [min.x, min.y], [max.x, max.y], [min.x, max.y]]
                encoder.setRenderPipelineState(self.pipeline)
                encoder.setVertexBytes(points, length: points.count * MemoryLayout<SIMD2<Float>>.stride, index: 0)
                encoder.setVertexBytes(&matrix, length: MemoryLayout<simd_float4x4>.stride, index: 1)
                encoder.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: points.count)
            }
        }
    }

    private func makeScene() throws -> (RenderTestScene, Painter) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = try RenderTestScene(device: device)
        try scene.submitMaterials([(redID, RenderMaterial(color: red)), (blueID, RenderMaterial(color: blue))])
        return (scene, try Painter(device: device))
    }

    // P-B-54: prostokąt z `afterBackground` leży pod warstwą 0, z `afterLayer(0)` nad warstwą 0 i pod warstwą 1,
    // z `overlay` nad wszystkim. Po każdym haku renderer wiąże bufory od nowa (po haku idzie kolejny ciąg baniek).
    func testHooksDrawBetweenBackgroundLayersAndOverlay() async throws {
        let (scene, painter) = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-6, 0], radius: 8, filter: ghost, role: .static, render: redID, layer: 0))
            .add(B.bubble(2, at: [6, 0], radius: 8, filter: ghost, role: .static, render: blueID, layer: 1)))
        await scene.step()
        let hooks = RenderHooks(
            afterBackground: painter.hook(min: [-20, -20], max: [20, 20], color: green),
            afterLayer: [0: painter.hook(min: [-20, -1], max: [20, 1], color: yellow)],
            overlay: painter.hook(min: [9, -3], max: [11, 3], color: magenta))
        try await scene.render(hooks: hooks)
        scene.assertPixel([-18, 6], green, "tło gry widać poza obiektami")
        scene.assertPixel([-6, 5], red, "warstwa 0 nad hakiem po tle")
        scene.assertPixel([6, 5], blue, "warstwa 1 nad hakiem po tle")
        scene.assertPixel([-10, 0], yellow, "hak warstwy 0 nad warstwą 0")
        scene.assertPixel([-18, 0], yellow, "hak warstwy 0 nad hakiem po tle")
        scene.assertPixel([0, 0], blue, "warstwa 1 nad hakiem warstwy 0 (wspólny obszar baniek)")
        scene.assertPixel([6, 0], blue, "warstwa 1 nad hakiem warstwy 0")
        scene.assertPixel([10, 0], magenta, "nakładka nad wszystkim")
        scene.assertPixel([10, 2.5], magenta, "nakładka nad warstwą 1")
    }

    // P-B-54: macierz przenosi punkt świata na właściwy piksel także przy przesuniętej i nierównej kamerze.
    func testMatrixMapsWorldPointsToTheRightPixels() async throws {
        let (scene, painter) = try makeScene()
        let viewport = try Viewport(center: [5, -3], size: [20, 40])
        var captured: simd_float4x4?
        let paint = painter.hook(min: [3, 2], max: [8, 6], color: magenta)
        let hooks = RenderHooks(overlay: { encoder, matrix in captured = matrix; try paint(encoder, matrix) })
        try await scene.render(viewport: viewport, hooks: hooks)
        for (point, label) in [(WorldPoint(3.4, 2.4), "róg"), (WorldPoint(5.5, 4), "środek"), (WorldPoint(7.6, 5.6), "przeciwny róg")] {
            scene.assertPixel(point, magenta, label, viewport: viewport)
        }
        for point: WorldPoint in [[2.4, 4], [8.6, 4], [5.5, 1.4], [5.5, 6.6]] {
            scene.assertPixel(point, black, "poza prostokątem \(point)", viewport: viewport)
        }
        let matrix = try XCTUnwrap(captured)
        for point: WorldPoint in [[5, -3], [15, 17], [-5, -23], [7.25, 1.5]] {
            let clip = matrix * SIMD4<Float>(point.x, point.y, 0, 1)
            XCTAssertEqual(clip.x, (point.x - 5) * 2 / 20, accuracy: 1e-5)
            XCTAssertEqual(clip.y, (point.y + 3) * 2 / 40, accuracy: 1e-5)
            XCTAssertEqual(clip.w, 1, accuracy: 1e-6)
        }
    }

    // P-B-54: `afterBackground` i `overlay` rysują także w świecie bez obiektów, przed pierwszym krokiem i po nim.
    func testHooksDrawInAnEmptyWorldBeforeAndAfterTheFirstStep() async throws {
        let (scene, painter) = try makeScene()
        let hooks = RenderHooks(
            afterBackground: painter.hook(min: [-12, -12], max: [12, 12], color: green),
            afterLayer: [3: painter.hook(min: [-6, -6], max: [6, 6], color: yellow)],
            overlay: painter.hook(min: [-2, -2], max: [2, 2], color: magenta))
        try await scene.render(hooks: hooks)
        scene.assertPixel([-9, 0], green, "przed pierwszym krokiem: po tle")
        scene.assertPixel([-4, 0], yellow, "przed pierwszym krokiem: warstwa bez obiektów")
        scene.assertPixel([0, 0], magenta, "przed pierwszym krokiem: nakładka")
        await scene.step()
        try await scene.render(hooks: hooks)
        scene.assertPixel([-9, 0], green, "po kroku bez obiektów: po tle")
        scene.assertPixel([-4, 0], yellow, "po kroku bez obiektów: warstwa bez obiektów")
        scene.assertPixel([0, 0], magenta, "po kroku bez obiektów: nakładka")
    }

    // P-B-54: hak warstwy bez obiektów rysuje w kolejności numerów warstw, między warstwami z obiektami.
    func testHookForALayerWithoutObjectsDrawsInLayerOrder() async throws {
        let (scene, painter) = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: [-6, 0], radius: 8, filter: ghost, role: .static, render: redID, layer: 0))
            .add(B.bubble(2, at: [6, 0], radius: 8, filter: ghost, role: .static, render: blueID, layer: 9)))
        await scene.step()
        let hooks = RenderHooks(afterLayer: [
            5: painter.hook(min: [-20, -1], max: [3, 1], color: magenta),
            2: painter.hook(min: [-20, -1], max: [20, 1], color: yellow)])
        try await scene.render(hooks: hooks)
        scene.assertPixel([-10, 0], magenta, "hak warstwy 5 nad hakiem warstwy 2 i nad warstwą 0")
        scene.assertPixel([-6, 4], red, "warstwa 0 poza paskiem")
        scene.assertPixel([8, 0], blue, "warstwa 9 nad hakami")
        scene.assertPixel([16, 0], yellow, "hak warstwy 2 poza bańkami")
    }

    // P-B-54: hak, który rzuca, odrzuca klatkę (`.frameRejected`), a następna klatka się udaje.
    func testThrowingHookRejectsTheFrameAndTheNextFrameSucceeds() async throws {
        let (scene, painter) = try makeScene()
        scene.world.submit(try WorldTransaction()
            .add(B.bubble(1, at: .zero, radius: 8, filter: ghost, role: .static, render: redID)))
        await scene.step()
        let viewport = RenderTestScene.viewport
        let world = scene.world, harness = scene.harness
        let failing = RenderHooks(afterLayer: [0: { _, _ in throw HookError() }])
        let rejected = try harness.makeCommandBuffer()
        _ = await world.advance(by: 0.001, commandBuffer: rejected) {
            try scene.renderer.encode(world: world, viewport: viewport, commandBuffer: rejected,
                                      renderPassDescriptor: harness.makePass(), hooks: failing)
        }
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .frameRejected)
        XCTAssertFalse(world.diagnostics.didRenderLastAdvance)
        XCTAssertEqual(rejected.status, .notEnqueued)
        XCTAssertNil(world.diagnostics.failureReason)

        let working = RenderHooks(overlay: painter.hook(min: [-2, -2], max: [2, 2], color: magenta))
        let accepted = try harness.makeCommandBuffer()
        _ = await world.advance(by: 0.001, commandBuffer: accepted) {
            try scene.renderer.encode(world: world, viewport: viewport, commandBuffer: accepted,
                                      renderPassDescriptor: harness.makePass(), hooks: working)
        }
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        XCTAssertTrue(world.diagnostics.didRenderLastAdvance)
        XCTAssertEqual(accepted.status, .completed)
        scene.assertPixel([0, 0], magenta, "nakładka następnej klatki")
        scene.assertPixel([6, 0], red, "bańka następnej klatki")
    }
}
