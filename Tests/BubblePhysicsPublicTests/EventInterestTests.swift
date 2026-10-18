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

    func testRemovingLastBodyEmitsSensorExitAndReaddedIDEnters() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-20, -20], max: [20, 20])))
        let material = PhysicsMaterialID(rawValue: 1), style = RenderStyleID(rawValue: 1)
        let bodyID = ObjectID(rawValue: 1), sensorID = ObjectID(rawValue: 9)
        let body = try BubbleDescriptor(id: bodyID, position: .zero, targetRadius: 1,
            physicsMaterialID: material, renderStyleID: style)
        let sensor = try SensorDescriptor(id: sensorID, position: .zero,
            geometry: RangeGeometry.circle(radius: 3), renderStyleID: style,
            eventInterest: [.enteredSensor, .exitedSensor])
        _ = world.submit(WorldTransaction().updatePhysicsMaterial(material, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(style, style: try RenderStyle()).add(.bubble(body)).add(.sensor(sensor)))
        let entered = await world.advance(by: 1.0 / 60.0)
        XCTAssertTrue(entered.events.contains(.enteredSensor(sensor: sensorID, object: bodyID)))
        _ = world.submit(WorldTransaction().remove(bodyID))
        let exited = await world.advance(by: 1.0 / 60.0)
        XCTAssertTrue(exited.events.contains(.exitedSensor(sensor: sensorID, object: bodyID)))
        _ = world.submit(WorldTransaction().add(.bubble(body)))
        let reentered = await world.advance(by: 1.0 / 60.0)
        XCTAssertTrue(reentered.events.contains(.enteredSensor(sensor: sensorID, object: bodyID)))
    }
}
