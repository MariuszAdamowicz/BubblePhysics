import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-80 (etap 8): sprzężenie zwrotne sterowania widzi wyłącznie obiekty sterowane, w kolejności `ObjectID`,
/// a wynik nie zależy od liczby i kolejności obiektów niesterowanych.
final class MotionControllersFeedbackTests: XCTestCase {
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func state(ids: [UInt64]) throws -> RuntimeState {
        let materialID = PhysicsMaterialID(rawValue: 2), styleID = RenderMaterialID(rawValue: 1)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(styleID, material: try RenderMaterial())
        for value in ids {
            transaction = transaction.add(.rigidBody(try RigidBodyDescriptor(id: id(value),
                vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], position: [Float(value % 50) * 5, 0], motionRole: .dynamic,
                physicsMaterialID: materialID, renderMaterialID: styleID)))
        }
        let state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000])))
        return try TransactionStager.stage(transaction, against: state).state
    }

    func testFeedbackListsOnlyDrivenObjectsInIDOrder() throws {
        var prepared = try state(ids: Array(1...60) + [900, 300])
        for value: UInt64 in [900, 5, 300, 41] { prepared.objects[id(value)]?.motionRole = .playerDriven
            prepared.objects[id(value)]?.playerDriveTarget = [3, 4] }
        prepared.objects[id(17)]?.motionRole = .pathDriven
        prepared.objects[id(17)]?.pathDrive = try PathDrive(points: [[40, 40]], speed: 5)
        // Sterowany graczem bez celu i obiekt dynamiczny nie dają wpisu.
        prepared.objects[id(8)]?.motionRole = .playerDriven
        let before = prepared
        let feedback = MotionControllers.feedback(&prepared, contacts: [:])
        XCTAssertEqual(feedback.map(\.objectID), [5, 17, 41, 300, 900].map(id))
        XCTAssertEqual(feedback.first { $0.objectID == id(5) }?.target, [3, 4])
        XCTAssertEqual(feedback.first { $0.objectID == id(17) }?.target, [40, 40])
        XCTAssertEqual(prepared, before, "bez blokady stan się nie zmienia")
    }

    func testBlockedPathObjectStopsAndOnlyItsRecordChanges() throws {
        var prepared = try state(ids: Array(1...30))
        prepared.objects[id(12)]?.motionRole = .pathDriven
        prepared.objects[id(12)]?.pathDrive = try PathDrive(points: [[100, 0]], speed: 5)
        prepared.objects[id(12)]?.velocity = [3, 0]
        prepared.objects[id(20)]?.motionRole = .playerDriven
        prepared.objects[id(20)]?.playerDriveTarget = [200, 0]
        let before = prepared
        // Normalna wskazuje od przeszkody do obiektu, czyli przeciwnie do kierunku celu (+x).
        let blocker = DriveBlockingContact(objectID: id(2), point: [1, 1], normal: [-1, 0])
        let feedback = MotionControllers.feedback(&prepared, contacts: [id(12): [blocker], id(20): [blocker]])
        let path = try XCTUnwrap(feedback.first { $0.objectID == id(12) })
        XCTAssertEqual(path.blockingContact, blocker)
        XCTAssertTrue(path.isStopped)
        XCTAssertEqual(prepared.objects[id(12)]?.pathStopped, true)
        XCTAssertEqual(prepared.objects[id(12)]?.pathBlocker, blocker)
        XCTAssertEqual(prepared.objects[id(12)]?.velocity, .zero)
        let player = try XCTUnwrap(feedback.first { $0.objectID == id(20) })
        XCTAssertEqual(player.blockingContact, blocker)
        XCTAssertFalse(player.isStopped)
        var expected = before
        expected.objects[id(12)] = prepared.objects[id(12)]
        XCTAssertEqual(prepared, expected)
    }
}
