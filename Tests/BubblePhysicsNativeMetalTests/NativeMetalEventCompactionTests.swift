import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

@MainActor
final class NativeMetalEventCompactionTests: XCTestCase {
    private let material = PhysicsMaterialID(rawValue: 1)
    private let style = RenderStyleID(rawValue: 1)

    private func bubble(_ id: UInt64, x: Float, interest: EventInterest = [], groups: MergeGroupSet = []) throws -> NativePublicObject {
        NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: id), position: [x, 0],
            targetRadius: 1, physicsMaterialID: material, renderStyleID: style,
            mergeGroups: groups, eventInterest: interest)))
    }

    private func step(_ world: NativePublicWorld, _ objects: [NativePublicObject], capacity: Int = 8) async throws -> NativePublicFrame {
        try await world.step(objects: objects, materials: [material: PhysicsMaterial(kind: .bubble)],
            styles: [style: RenderStyle()], region: WorldRectangle(min: [-20, -20], max: [20, 20]),
            duration: 1.0 / 60.0, eventBufferCapacity: capacity)
    }

    func testMergeContactRequiresBothInterestAndOverlappingUInt64GroupBit() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let high = MergeGroupSet(rawValue: 1 << 63)
        let oneSided = try await step(world, [bubble(1, x: -0.5, interest: .mergeContact, groups: high),
            bubble(2, x: 0.5, groups: high)])
        XCTAssertFalse(oneSided.events.contains { if case .mergeContact = $0 { return true }; return false })
        let disjoint = try await step(world, [bubble(1, x: -0.5, interest: .mergeContact, groups: high),
            bubble(2, x: 0.5, interest: .mergeContact, groups: MergeGroupSet(rawValue: 1 << 62))])
        XCTAssertFalse(disjoint.events.contains { if case .mergeContact = $0 { return true }; return false })
        let compatible = try await step(world, [bubble(1, x: -0.5, interest: .mergeContact, groups: high),
            bubble(2, x: 0.5, interest: .mergeContact, groups: high)])
        XCTAssertTrue(compatible.events.contains { if case .mergeContact = $0 { return true }; return false })
    }

    func testSensorPublishesOnlyEnterAndExit() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: ObjectID(rawValue: 9),
            position: .zero, geometry: RangeGeometry.circle(radius: 2), renderStyleID: style,
            eventInterest: [.enteredSensor, .exitedSensor])))
        var body = try bubble(1, x: 0)
        let entered = try await step(world, [body, sensor])
        XCTAssertEqual(entered.events, [.enteredSensor(sensor: ObjectID(rawValue: 9), object: ObjectID(rawValue: 1))])
        let staying = try await step(world, [body, sensor])
        XCTAssertTrue(staying.events.isEmpty)
        body.position = [6, 0]; body.previousPosition = body.position
        let exited = try await step(world, [body, sensor])
        XCTAssertEqual(exited.events, [.exitedSensor(sensor: ObjectID(rawValue: 9), object: ObjectID(rawValue: 1))])
    }

    func testSensorPairSearchPreservesFullUInt64Ordering() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let sensorID = ObjectID(rawValue: 9)
        let low = ObjectID(rawValue: 1), high = ObjectID(rawValue: UInt64.max)
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: sensorID,
            position: .zero, geometry: RangeGeometry.circle(radius: 5), renderStyleID: style,
            eventInterest: [.enteredSensor, .exitedSensor])))
        var first = try bubble(low.rawValue, x: -2)
        var second = try bubble(high.rawValue, x: 2)
        let entered = try await step(world, [first, second, sensor])
        XCTAssertEqual(entered.events.count, 2)
        XCTAssertTrue(entered.events.contains(.enteredSensor(sensor: sensorID, object: low)))
        XCTAssertTrue(entered.events.contains(.enteredSensor(sensor: sensorID, object: high)))
        let staying = try await step(world, [first, second, sensor])
        XCTAssertTrue(staying.events.isEmpty)
        first.position = [-12, 0]; first.previousPosition = first.position
        second.position = [12, 0]; second.previousPosition = second.position
        let exited = try await step(world, [first, second, sensor])
        XCTAssertEqual(exited.events.count, 2)
        XCTAssertTrue(exited.events.contains(.exitedSensor(sensor: sensorID, object: low)))
        XCTAssertTrue(exited.events.contains(.exitedSensor(sensor: sensorID, object: high)))
    }

    func testRemovingObservedBubbleEmitsExitAndReaddedIDEnters() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let sensorID = ObjectID(rawValue: 9), observedID = ObjectID(rawValue: 1)
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: sensorID,
            position: .zero, geometry: RangeGeometry.circle(radius: 3), renderStyleID: style,
            eventInterest: [.enteredSensor, .exitedSensor])))
        let observed = try bubble(observedID.rawValue, x: 0)
        let other = try bubble(2, x: 10)
        let entered = try await step(world, [observed, other, sensor])
        XCTAssertEqual(entered.events, [.enteredSensor(sensor: sensorID, object: observedID)])
        let exited = try await step(world, [other, sensor])
        XCTAssertEqual(exited.events, [.exitedSensor(sensor: sensorID, object: observedID)])
        let reentered = try await step(world, [observed, other, sensor])
        XCTAssertEqual(reentered.events, [.enteredSensor(sensor: sensorID, object: observedID)])
    }

    func testRemovedPairExitsRespectEventCapacityAndOverflow() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let sensorID = ObjectID(rawValue: 9)
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: sensorID,
            position: .zero, geometry: RangeGeometry.circle(radius: 3), renderStyleID: style,
            eventInterest: [.enteredSensor, .exitedSensor])))
        let first = try bubble(1, x: -1), second = try bubble(2, x: 1)
        _ = try await step(world, [first, second, sensor], capacity: 2)
        let removed = try await step(world, [sensor], capacity: 1)
        XCTAssertEqual(removed.events.count, 1)
        XCTAssertEqual(removed.eventOverflow.droppedCount, 1)
        XCTAssertTrue(removed.events.allSatisfy {
            if case .exitedSensor(let id, _) = $0 { return id == sensorID }
            return false
        })
        let cleared = try await step(world, [sensor], capacity: 1)
        XCTAssertTrue(cleared.events.isEmpty)
        XCTAssertEqual(cleared.eventOverflow.droppedCount, 0)
    }

    func testEventBufferOverflowIsReportedInsteadOfSilentlyDroppingIt() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: ObjectID(rawValue: 9),
            position: .zero, geometry: RangeGeometry.circle(radius: 3), renderStyleID: style,
            eventInterest: .enteredSensor)))
        let frame = try await step(world, [try bubble(1, x: -1), try bubble(2, x: 1), sensor], capacity: 1)
        XCTAssertEqual(frame.events.count, 1)
        XCTAssertEqual(frame.eventOverflow.droppedCount, 1)
    }

    func testPolygonObjectEntersAndExitsPolygonSensor() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let polygonMaterial = PhysicsMaterialID(rawValue: 2)
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: ObjectID(rawValue: 9),
            position: .zero, geometry: RangeGeometry.polygon(vertices: [[-2, -2], [2, -2], [2, 2], [-2, 2]]),
            renderStyleID: style, eventInterest: [.enteredSensor, .exitedSensor])))
        var body = NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: ObjectID(rawValue: 3),
            vertices: [[-0.5, -0.5], [0.5, -0.5], [0.5, 0.5], [-0.5, 0.5]],
            physicsMaterialID: polygonMaterial, renderStyleID: style)))
        func run() async throws -> NativePublicFrame {
            try await world.step(objects: [body, sensor], materials: [polygonMaterial: PhysicsMaterial(kind: .polygon)],
                styles: [style: RenderStyle()], region: WorldRectangle(min: [-20, -20], max: [20, 20]),
                duration: 1.0 / 60.0)
        }
        let entered = try await run()
        XCTAssertEqual(entered.events, [.enteredSensor(sensor: ObjectID(rawValue: 9), object: ObjectID(rawValue: 3))])
        let staying = try await run()
        XCTAssertTrue(staying.events.isEmpty)
        body.position = [7, 0]
        let exited = try await run()
        XCTAssertEqual(exited.events, [.exitedSensor(sensor: ObjectID(rawValue: 9), object: ObjectID(rawValue: 3))])
    }

    func testRemovingObservedPolygonEmitsExitAndReaddedIDEnters() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let polygonMaterial = PhysicsMaterialID(rawValue: 2)
        let sensorID = ObjectID(rawValue: 9), bodyID = ObjectID(rawValue: 3)
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: sensorID,
            position: .zero, geometry: RangeGeometry.circle(radius: 3), renderStyleID: style,
            eventInterest: [.enteredSensor, .exitedSensor])))
        let body = NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: bodyID,
            vertices: [[-0.5, -0.5], [0.5, -0.5], [0.5, 0.5], [-0.5, 0.5]],
            physicsMaterialID: polygonMaterial, renderStyleID: style)))
        func run(_ objects: [NativePublicObject]) async throws -> NativePublicFrame {
            try await world.step(objects: objects, materials: [polygonMaterial: PhysicsMaterial(kind: .polygon)],
                styles: [style: RenderStyle()], region: WorldRectangle(min: [-20, -20], max: [20, 20]),
                duration: 1.0 / 60.0)
        }
        let entered = try await run([body, sensor])
        XCTAssertEqual(entered.events, [.enteredSensor(sensor: sensorID, object: bodyID)])
        let exited = try await run([sensor])
        XCTAssertEqual(exited.events, [.exitedSensor(sensor: sensorID, object: bodyID)])
        let reentered = try await run([body, sensor])
        XCTAssertEqual(reentered.events, [.enteredSensor(sensor: sensorID, object: bodyID)])
    }

    func testWrapEventRequiresInterest() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let interested = NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: 1),
            position: [9, 5], velocity: [20, 0], targetRadius: 1, regionExitPolicy: .wrap,
            physicsMaterialID: material, renderStyleID: style, eventInterest: .didWrap)))
        let frame = try await world.step(objects: [interested], materials: [material: PhysicsMaterial(kind: .bubble)],
            styles: [style: RenderStyle()], region: WorldRectangle(min: [0, 0], max: [10, 10]), duration: 0.25)
        XCTAssertEqual(frame.events, [.didWrap(ObjectID(rawValue: 1))])
    }

    func testPolygonSensorIgnoresDistantCollinearEdges() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let polygonMaterial = PhysicsMaterialID(rawValue: 2)
        let sensor = NativePublicObject(descriptor: .sensor(try SensorDescriptor(id: ObjectID(rawValue: 9),
            position: .zero, geometry: RangeGeometry.polygon(vertices: [[-2, -2], [2, -2], [2, 2], [-2, 2]]),
            renderStyleID: style, eventInterest: .enteredSensor)))
        let body = NativePublicObject(descriptor: .polygon(try PolygonDescriptor(id: ObjectID(rawValue: 3),
            vertices: [[-0.5, -2], [0.5, -2], [0, -1]], position: [7, 0],
            physicsMaterialID: polygonMaterial, renderStyleID: style)))
        let frame = try await world.step(objects: [body, sensor],
            materials: [polygonMaterial: PhysicsMaterial(kind: .polygon)],
            styles: [style: RenderStyle()], region: WorldRectangle(min: [-20, -20], max: [20, 20]),
            duration: 1.0 / 60.0)
        XCTAssertTrue(frame.events.isEmpty)
    }
}
