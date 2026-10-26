import BubblePhysics
import Metal
import XCTest

@MainActor
final class DeformedContourSelectionTests: XCTestCase {
    // This catches a selection implementation that answers an arbitrary queued point.
    func testSelectionAnswersItsOwnPointAfterPublishedFrame() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion: .init(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60), device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        world.submit(WorldTransaction().updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble)).updateRenderStyle(style, style: try RenderStyle()).add(.bubble(try BubbleDescriptor(id: .init(rawValue: 7), position: .zero, targetRadius: 2, physicsMaterialID: material, renderStyleID: style))))
        _ = await world.advance(by: 1.0 / 60)
        async let inside = world.selectBubble(at: .zero)
        async let empty = world.selectBubble(at: [8, 8])
        await Task.yield()
        _ = await world.advance(by: 1.0 / 60)
        let insideResult = await inside
        let emptyResult = await empty
        XCTAssertEqual(insideResult, .init(rawValue: 7))
        XCTAssertNil(emptyResult)
        XCTAssertEqual(world.benchmarkFrameProfile?.commandBufferCount, 1)
        XCTAssertEqual(world.benchmarkFrameProfile?.encoderCount, 3)
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }

    func testSelectionSurvivesFailedRenderUntilTheNextPublishedFrame() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion: .init(min: [-10, -10], max: [10, 10]), fixedTimeStep: 1.0 / 60), device: device)
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        world.submit(WorldTransaction().updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble)).updateRenderStyle(style, style: try RenderStyle()).add(.bubble(try BubbleDescriptor(id: .init(rawValue: 7), position: .zero, targetRadius: 2, physicsMaterialID: material, renderStyleID: style))))
        _ = await world.advance(by: 1.0 / 60)

        async let selection = world.selectBubble(at: .zero)
        await Task.yield()
        let failed = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        _ = await world.advance(by: 1.0 / 60, commandBuffer: failed) { throw RenderFailure.expected }
        XCTAssertEqual(world.diagnostics.lastAdvanceIssue, .stepFailed)

        _ = await world.advance(by: 1.0 / 60)
        let selected = await selection
        XCTAssertEqual(selected, .init(rawValue: 7))
    }
}

private enum RenderFailure: Error { case expected }
