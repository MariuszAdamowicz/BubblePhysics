import BubblePhysics
import Metal
import XCTest

@MainActor
final class SemanticPresentationTests: XCTestCase {
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
}
