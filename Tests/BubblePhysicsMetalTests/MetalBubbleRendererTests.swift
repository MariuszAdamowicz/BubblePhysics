import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalBubbleRendererTests: XCTestCase {
    func testSceneResourcesMatchAdaptiveGeometryForInspectionAndStressScenes() throws {
        let renderer = try makeRenderer()
        for size in [PrototypeSceneSize.inspection, .stress] {
            let snapshot = MetalWorldSnapshot(world: try PrototypeSceneFactory.make(size))
            renderer.rebuildSceneResources(ranges: snapshot.bubbleRanges, labels: snapshot.bubbleRanges.map { String($0.id) })
            let expected = BubbleRenderGeometry.build(ranges: snapshot.bubbleRanges)
            XCTAssertEqual(renderer.sceneStatistics.bubbleCount, snapshot.bubbleRanges.count)
            XCTAssertEqual(renderer.sceneStatistics.fillIndexCount, expected.fillIndices.count)
            XCTAssertEqual(renderer.sceneStatistics.outlineIndexCount, expected.outlineIndices.count)
        }
    }

    func testColorIsStableForBubbleIdentifier() {
        XCTAssertEqual(MetalBubbleRenderer.color(for: 2048), MetalBubbleRenderer.color(for: 2048))
        XCTAssertNotEqual(MetalBubbleRenderer.color(for: 2), MetalBubbleRenderer.color(for: 2048))
    }

    func testRendererUsesEvenOddFillForDeformableContours() throws {
        XCTAssertEqual(try makeRenderer().fillRule, .evenOdd)
    }

    func testAtlasContainsEveryLabelAndIsNotRebuiltForUnchangedScene() throws {
        let renderer = try makeRenderer()
        let ranges = [range(2), range(4), range(8)]
        renderer.rebuildSceneResources(ranges: ranges, labels: ["2", "4", "8"])
        let first = renderer.atlasBuildCount
        XCTAssertEqual(renderer.labelCount, 3)
        renderer.rebuildSceneResources(ranges: ranges, labels: ["2", "4", "8"])
        XCTAssertEqual(renderer.atlasBuildCount, first)
    }

    func testEncodeSafelySkipsMissingRenderPass() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let renderer = try MetalBubbleRenderer(device: device, pixelFormat: .bgra8Unorm, worldBounds: PrototypeSceneFactory.bounds)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        XCTAssertFalse(try renderer.encode(frame: nil, diagnostics: false, renderPass: nil, drawableSize: .init(width: 0, height: 0), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())))
    }

    private func makeRenderer() throws -> MetalBubbleRenderer {
        try MetalBubbleRenderer(device: XCTUnwrap(MTLCreateSystemDefaultDevice()), pixelFormat: .bgra8Unorm, worldBounds: PrototypeSceneFactory.bounds)
    }

    private func range(_ id: UInt32) -> MetalBubbleRange {
        MetalBubbleRange(id: id, centerIndex: id, boundaryStart: id + 1, boundaryCount: 8, restArea: 100)
    }
}
