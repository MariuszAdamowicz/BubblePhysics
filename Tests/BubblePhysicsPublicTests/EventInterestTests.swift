import BubblePhysics
import XCTest

@MainActor
final class EventInterestTests: XCTestCase {
    func testNoContactEventIsPublishedWithoutInterest() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-20, -20], max: [20, 20])))
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        let a = try BubbleDescriptor(id: ObjectID(rawValue: 1), position: [-0.5, 0],
            targetRadius: 1, physicsMaterialID: material, renderStyleID: style)
        let b = try BubbleDescriptor(id: ObjectID(rawValue: 2), position: [0.5, 0],
            targetRadius: 1, physicsMaterialID: material, renderStyleID: style)
        let physics = try PhysicsMaterial(kind: .bubble)
        let render = try RenderStyle()
        _ = world.submit(WorldTransaction().updatePhysicsMaterial(material, material: physics)
            .updateRenderStyle(style, style: render).add(.bubble(a)).add(.bubble(b)))
        let frame = await world.advance(by: 1.0 / 60.0)
        XCTAssertFalse(frame.events.contains { if case .mergeContact = $0 { return true }; return false })
        XCTAssertEqual(frame.eventOverflow.droppedCount, 0)
    }

    func testMergeGroupSetUsesAllSixtyFourBits() {
        let high = MergeGroupSet(rawValue: 1 << 63)
        XCTAssertTrue(high.overlaps(high))
        XCTAssertFalse(high.overlaps(MergeGroupSet(rawValue: 1 << 62)))
    }
}
