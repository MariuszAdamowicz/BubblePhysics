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

    // Zastąpienie konturu promieniem, pominięcie granicy lub pierwsze trafienie
    // zamiast ostatniego renderowanego obiektu złamie ten kontrakt.
    func testDeformedContourSelectionUsesPublishedGPUGeometryWithoutCPUReadback() async throws {
        let world = try makeWorld()
        let deformed = ObjectID(rawValue: 7), first = ObjectID(rawValue: 9)
        let last = ObjectID(rawValue: 11), isolated = ObjectID(rawValue: 13)
        let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
        let polygonMaterial = PhysicsMaterialID(rawValue: 2)
        let style = RenderStyleID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .polygon))
            .updateRenderStyle(style, style: RenderStyle())
            .add(.bubble(BubbleDescriptor(id: deformed, position: [-0.6, 0], targetRadius: 1,
                physicsMaterialID: bubbleMaterial, renderStyleID: style)))
            .add(.bubble(BubbleDescriptor(id: first, position: [-6, 0], targetRadius: 1, motionRole: .static,
                physicsMaterialID: bubbleMaterial, renderStyleID: style)))
            .add(.bubble(BubbleDescriptor(id: last, position: [-6, 0], targetRadius: 1, motionRole: .static,
                physicsMaterialID: bubbleMaterial, renderStyleID: style)))
            .add(.bubble(BubbleDescriptor(id: isolated, position: [6, 0], targetRadius: 1, motionRole: .static,
                physicsMaterialID: bubbleMaterial, renderStyleID: style)))
            .add(.polygon(PolygonDescriptor(id: .init(rawValue: 10), vertices: [[0, -10], [2, -10], [2, 10], [0, 10]],
                physicsMaterialID: polygonMaterial, renderStyleID: style))))
        _ = await world.advance(by: 1.0 / 60)

        async let inside = world.selectBubble(at: [-6, 0])
        async let boundary = world.selectBubble(at: [7, 0])
        // Punkt za spłaszczoną stroną konturu przy ścianie nie może zostać wybrany.
        async let recess = world.selectBubble(at: [0.05, 0])
        async let overlap = world.selectBubble(at: [-6, 0])
        for _ in 0..<10 { await Task.yield() }
        _ = await world.advance(by: 1.0 / 60)

        let insideResult = await inside
        let boundaryResult = await boundary
        let recessResult = await recess
        let overlapResult = await overlap
        XCTAssertEqual(insideResult, last)
        XCTAssertEqual(boundaryResult, isolated)
        XCTAssertNil(recessResult)
        XCTAssertEqual(overlapResult, last)
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }

    func testSelectionFeedsPlayerDriveWithoutContourReadback() async throws {
        let world = try makeWorld()
        let id = ObjectID(rawValue: 7)
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(style, style: RenderStyle())
            .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 1,
                physicsMaterialID: material, renderStyleID: style))))
        _ = await world.advance(by: 1.0 / 60)

        async let selected = world.selectBubble(at: .zero)
        for _ in 0..<10 { await Task.yield() }
        _ = await world.advance(by: 1.0 / 60)
        guard let selectedID = await selected else { return XCTFail("Expected selected bubble") }

        world.submit(WorldTransaction().beginPlayerDrive(selectedID, target: [2, 0]))
        let began = await world.advance(by: 1.0 / 60)
        let beganFeedback = try XCTUnwrap(began.driveFeedback.first)
        XCTAssertEqual(beganFeedback.objectID, id)
        XCTAssertEqual(beganFeedback.target, [2, 0])

        world.submit(WorldTransaction().updatePlayerDrive(selectedID, target: [3, 0]))
        let updated = await world.advance(by: 1.0 / 60)
        let updatedFeedback = try XCTUnwrap(updated.driveFeedback.first)
        XCTAssertEqual(updatedFeedback.playerDriveID, beganFeedback.playerDriveID)
        XCTAssertEqual(updatedFeedback.target, [3, 0])

        world.submit(WorldTransaction().endPlayerDrive(selectedID))
        let ended = await world.advance(by: 1.0 / 60)
        XCTAssertTrue(ended.driveFeedback.isEmpty)
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }

    func testEmptyOrRemovedSelectionNeverBeginsPlayerDrive() async throws {
        let world = try makeWorld()
        let id = ObjectID(rawValue: 7)
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(style, style: RenderStyle())
            .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 1,
                physicsMaterialID: material, renderStyleID: style))))
        _ = await world.advance(by: 1.0 / 60)

        async let empty = world.selectBubble(at: [8, 8])
        async let removed = world.selectBubble(at: .zero)
        for _ in 0..<10 { await Task.yield() }
        world.submit(WorldTransaction().remove(id))
        let frame = await world.advance(by: 1.0 / 60)

        let emptyResult = await empty
        let removedResult = await removed
        XCTAssertNil(emptyResult)
        XCTAssertNil(removedResult)
        XCTAssertTrue(frame.driveFeedback.isEmpty)
        XCTAssertEqual(world.benchmarkContourCPUReadbackCount, 0)
    }

    private func makeWorld() throws -> BubbleWorld {
        try BubbleWorld(configuration: WorldConfiguration(simulationRegion: .init(min: [-10, -10], max: [10, 10]),
            fixedTimeStep: 1.0 / 60), device: try XCTUnwrap(MTLCreateSystemDefaultDevice()))
    }
}

private enum RenderFailure: Error { case expected }
