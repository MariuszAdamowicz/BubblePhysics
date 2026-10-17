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
