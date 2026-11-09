import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

/// P-B-31, P-B-32: kernel `nativeHitTest` przez `NativePublicWorld`, bez warstwy świata.
/// Wynik dla każdego punktu liczony jest na stanie tego kroku: kontury baniek (parzystość przecięć) i dokładne bryły.
@MainActor
final class NativeMetalHitTestTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func step(_ objects: [WorldObject], hitTests: [WorldPoint], world: NativePublicWorld? = nil) async throws -> NativePublicFrame {
        try await step(objects.map { NativePublicObject(descriptor: $0) }, hitTests: hitTests, world: world)
    }

    /// Obiekty z warstwą ustawioną na `NativePublicObject`, jak robi to stepper z `RuntimeObject.layer`.
    private func step(layered objects: [(WorldObject, Int32)], hitTests: [WorldPoint]) async throws -> NativePublicFrame {
        try await step(objects.map { descriptor, layer in
            var object = NativePublicObject(descriptor: descriptor); object.layer = layer; return object
        }, hitTests: hitTests)
    }

    private func step(_ objects: [NativePublicObject], hitTests: [WorldPoint], world: NativePublicWorld? = nil) async throws -> NativePublicFrame {
        let world = try world ?? NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        return try await world.step(objects: objects,
            materials: [bubbleMaterial: PhysicsMaterial(kind: .bubble), rigidMaterial: PhysicsMaterial(kind: .rigid)],
            region: WorldRectangle(min: [-100, -100], max: [100, 100]),
            duration: 1.0 / 60, hitTests: hitTests)
    }

    private func bubble(_ value: UInt64, at position: WorldPoint, radius: Float = 5) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, targetRadius: radius, motionRole: .static,
            physicsMaterialID: bubbleMaterial, renderMaterialID: style))
    }

    private func rigid(_ value: UInt64, _ shape: RigidShape, at position: WorldPoint, rotation: Float = 0) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), shape: shape, position: position, rotation: rotation,
            motionRole: .static, physicsMaterialID: rigidMaterial, renderMaterialID: style))
    }

    func testResultsFollowThePointOrderAndNameBubblesAndBodies() async throws {
        let box = try PolygonGeometry(vertices: [[-5, -5], [5, -5], [5, 5], [-5, 5]])
        let frame = try await step([
            bubble(1, at: [-60, 0]), rigid(2, .polygon(box), at: [-20, 0]),
            rigid(3, .circle(radius: 5), at: [20, 0]), rigid(4, .capsule(halfLength: 8, radius: 3), at: [60, 0])],
            hitTests: [[60, 2], [-60, 0], [-20, 4], [0, 0], [20, 3], [60, 10], [68, 2], [20, 8], [-20, 6]])
        XCTAssertEqual(frame.hitTestResults, [id(4), id(1), id(2), nil, id(3), nil, id(4), nil, nil])
    }

    func testNoPointsGiveNoResults() async throws {
        let frame = try await step([bubble(1, at: [0, 0])], hitTests: [])
        XCTAssertEqual(frame.hitTestResults, [])
    }

    func testPolygonIsHitOnItsRotatedShapeNotItsBounds() async throws {
        let box = try PolygonGeometry(vertices: [[-5, -5], [5, -5], [5, 5], [-5, 5]])
        let frame = try await step([rigid(2, .polygon(box), at: [0, 0], rotation: .pi / 4)],
            hitTests: [[6, 0], [4.5, 4.5], [0, 6], [-5, -5]])
        XCTAssertEqual(frame.hitTestResults, [id(2), nil, id(2), nil])
    }

    func testLargestObjectIDWinsAndInsertionOrderDoesNotMatter() async throws {
        let box = try PolygonGeometry(vertices: [[-3, -3], [3, -3], [3, 3], [-3, 3]])
        let frame = try await step([bubble(30, at: [0, 0]), rigid(7, .polygon(box), at: [0, 0]),
                                    bubble(12, at: [0, 0]), rigid(90, .circle(radius: 2), at: [40, 0]),
                                    bubble(50, at: [40, 0])],
            hitTests: [[0, 0], [40, 0], [4, 0]])
        XCTAssertEqual(frame.hitTestResults, [id(30), id(90), id(30)])
    }

    func testBubbleContourAnswersOnTheStateOfTheSameStep() async throws {
        // Bańka dynamiczna leci z prędkością 60/s, więc po kroku jej środek jest 1 jednostkę dalej.
        let moving = try WorldObject.bubble(BubbleDescriptor(id: id(1), position: [0, 0], velocity: [60, 0],
            targetRadius: 5, physicsMaterialID: bubbleMaterial, renderMaterialID: style))
        let frame = try await step([moving], hitTests: [[5.5, 0], [-5.5, 0]])
        XCTAssertEqual(frame.hitTestResults, [id(1), nil], "kontur z kroku t+1, nie z wejścia")
    }

    func testObjectsRemovedByTheRegionDoNotTakePart() async throws {
        // Bańka w całości poza regionem jest usuwana w tym kroku, więc jej kontur nie bierze udziału.
        let outside = try WorldObject.bubble(BubbleDescriptor(id: id(1), position: [110, 0], targetRadius: 2,
            physicsMaterialID: bubbleMaterial, renderMaterialID: style))
        let frame = try await step([outside, bubble(2, at: [0, 0])], hitTests: [[110, 0], [0, 0]])
        XCTAssertNil(frame.objects[id(1)])
        XCTAssertEqual(frame.hitTestResults, [nil, id(2)])
    }

    func testRigidBodyRemovedByTheRegionDoesNotTakePart() async throws {
        // Dynamiczna bryła w całości poza regionem jest usuwana w tym kroku (`flags.z == 1`), więc nie bierze udziału.
        let box = try PolygonGeometry(vertices: [[-5, -5], [5, -5], [5, 5], [-5, 5]])
        let outside = try WorldObject.rigidBody(RigidBodyDescriptor(id: id(1), shape: .polygon(box), position: [150, 0],
            motionRole: .dynamic, physicsMaterialID: rigidMaterial, renderMaterialID: style))
        let frame = try await step([outside, rigid(2, .polygon(box), at: [0, 0])], hitTests: [[150, 0], [0, 0]])
        XCTAssertNil(frame.objects[id(1)])
        XCTAssertEqual(frame.hitTestResults, [nil, id(2)])
    }

    func testRepeatedStepsAnswerEachTimeFromTheirOwnState() async throws {
        let world = try NativePublicWorld(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let objects = [try bubble(1, at: [0, 0])]
        let first = try await step(objects, hitTests: [[0, 0]], world: world)
        let second = try await step(objects, hitTests: [[50, 0], [0, 0]], world: world)
        XCTAssertEqual(first.hitTestResults, [id(1)])
        XCTAssertEqual(second.hitTestResults, [nil, id(1)])
    }

    // P-B-71: wyższa warstwa wygrywa z większym ObjectID, bańka z bryłą i bryła z bańką; w tej samej warstwie rozstrzyga ObjectID.
    func testHigherLayerWinsOverLargerObjectIDForBubblesAndBodies() async throws {
        let box = try PolygonGeometry(vertices: [[-3, -3], [3, -3], [3, 3], [-3, 3]])
        let frame = try await step(layered: [
            (bubble(30, at: [0, 0]), 0), (rigid(7, .polygon(box), at: [0, 0]), 3),
            (rigid(40, .circle(radius: 4), at: [40, 0]), 0), (bubble(2, at: [40, 0]), 5),
            (bubble(8, at: [80, 0]), 1), (rigid(9, .capsule(halfLength: 2, radius: 2), at: [80, 0]), 1)],
            hitTests: [[0, 0], [40, 0], [80, 0], [-4, 0]])
        XCTAssertEqual(frame.hitTestResults, [id(7), id(2), id(9), id(30)])
    }

    // P-B-71: warstwy ujemne i skrajne porządkują się jak Int32, a nie jak liczby bez znaku.
    func testNegativeAndExtremeLayersOrderLikeSignedIntegers() async throws {
        let frame = try await step(layered: [
            (bubble(90, at: [0, 0]), -1), (bubble(2, at: [0, 0]), 0),
            (bubble(91, at: [40, 0]), Int32.min), (bubble(3, at: [40, 0]), -2),
            (bubble(4, at: [80, 0]), Int32.max), (bubble(95, at: [80, 0]), Int32.max - 1),
            (bubble(5, at: [120, 0]), -3), (bubble(77, at: [120, 0]), -3)],
            hitTests: [[0, 0], [40, 0], [80, 0], [120, 0]])
        XCTAssertEqual(frame.hitTestResults, [id(2), id(3), id(4), id(77)])
    }
}
