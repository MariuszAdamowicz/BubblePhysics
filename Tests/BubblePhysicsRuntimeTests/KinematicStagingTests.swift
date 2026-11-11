import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-17: rola `kinematic` jest dostępna tylko dla brył; `setKinematicDrive` wymaga roli kinematycznej.
final class KinematicStagingTests: XCTestCase {
    private let materialID = PhysicsMaterialID(rawValue: 1)
    private let polygonMaterialID = PhysicsMaterialID(rawValue: 2)
    private let styleID = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func state() throws -> RuntimeState {
        RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-100, -100], max: [100, 100])))
    }
    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(polygonMaterialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(styleID, material: try RenderMaterial())
    }
    private func bubble(_ value: UInt64, role: MotionRole = .dynamic) throws -> BubbleDescriptor {
        try BubbleDescriptor(id: id(value), position: .zero, targetRadius: 1, motionRole: role,
                             physicsMaterialID: materialID, renderMaterialID: styleID)
    }
    private func box(_ value: UInt64, role: MotionRole) throws -> RigidBodyDescriptor {
        try RigidBodyDescriptor(id: id(value), vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], motionRole: role,
                              physicsMaterialID: polygonMaterialID, renderMaterialID: styleID)
    }
    private func assertRejected(_ transaction: WorldTransaction, against state: RuntimeState, index: Int,
                                reason: TransactionRejectionReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TransactionStager.stage(transaction, against: state), file: file, line: line) { error in
            XCTAssertEqual(error as? TransactionRejection, TransactionRejection(operationIndex: index, reason: reason),
                           file: file, line: line)
        }
    }

    func testKinematicBubbleIsRejectedOnAddReplaceAndSetMotion() throws {
        let kinematic = MotionRole.kinematic
        let initial = try state()
        assertRejected(try resources().add(.bubble(bubble(1, role: .kinematic))), against: initial, index: 3,
                       reason: .unsupportedMotionRole(id(1), kinematic))
        let seeded = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        assertRejected(WorldTransaction().replace(id(1), with: .bubble(try bubble(1, role: .kinematic))),
                       against: seeded, index: 0, reason: .unsupportedMotionRole(id(1), kinematic))
        assertRejected(WorldTransaction().setMotion(id(1), role: .kinematic), against: seeded, index: 0,
                       reason: .unsupportedMotionRole(id(1), kinematic))
    }

    func testKinematicPolygonIsAcceptedAndCarriesItsDrive() throws {
        let seeded = try TransactionStager.stage(resources().add(.rigidBody(box(2, role: .static))), against: state()).state
        let kinematic = try TransactionStager.stage(WorldTransaction().setMotion(id(2), role: .kinematic), against: seeded).state
        XCTAssertEqual(kinematic.objects[id(2)]?.motionRole, .kinematic)
        let drive = KinematicDrive.velocity(linear: [1, 0], angular: 0.5)
        let driven = try TransactionStager.stage(WorldTransaction().setKinematicDrive(id(2), drive: drive), against: kinematic).state
        XCTAssertEqual(driven.objects[id(2)]?.kinematicDrive, drive)
    }

    func testSetKinematicDriveForAnotherRoleOrMissingObjectIsRejected() throws {
        let drive = KinematicDrive.target(position: [3, 3], rotation: 0)
        let seeded = try TransactionStager.stage(resources().add(.rigidBody(box(2, role: .dynamic))).add(.bubble(bubble(1))),
                                                 against: state()).state
        assertRejected(WorldTransaction().setKinematicDrive(id(2), drive: drive), against: seeded, index: 0,
                       reason: .incompatibleMotionRole(id(2)))
        assertRejected(WorldTransaction().setKinematicDrive(id(1), drive: drive), against: seeded, index: 0,
                       reason: .incompatibleMotionRole(id(1)))
        assertRejected(WorldTransaction().setKinematicDrive(id(9), drive: drive), against: seeded, index: 0,
                       reason: .objectNotFound(id(9)))
    }

    func testLeavingKinematicRoleDiscardsTheDrive() throws {
        let seeded = try TransactionStager.stage(resources().add(.rigidBody(box(2, role: .kinematic)))
            .setKinematicDrive(id(2), drive: .velocity(linear: [1, 0], angular: 0)), against: state()).state
        XCTAssertNotNil(seeded.objects[id(2)]?.kinematicDrive)
        let dynamic = try TransactionStager.stage(WorldTransaction().setMotion(id(2), role: .dynamic), against: seeded).state
        XCTAssertNil(dynamic.objects[id(2)]?.kinematicDrive)
    }

    /// Napęd z NaN albo ∞ ma być odrzucony przy wejściu transakcji (jak siła globalna i impuls);
    /// inaczej błąd wychodzi dopiero w kroku i każdy kolejny `advance` odrzuca krok.
    func testNonFiniteKinematicDriveIsRejectedAtStaging() throws {
        let seeded = try TransactionStager.stage(resources().add(.rigidBody(box(2, role: .kinematic))), against: state()).state
        let cases: [(KinematicDrive, String)] = [
            (.velocity(linear: [.nan, 0], angular: 0), "kinematicDrive.linear"),
            (.velocity(linear: [0, .infinity], angular: 0), "kinematicDrive.linear"),
            (.velocity(linear: [1, 0], angular: .nan), "kinematicDrive.angular"),
            (.target(position: [.infinity, 0], rotation: 0), "kinematicDrive.position"),
            (.target(position: [0, 1], rotation: -.infinity), "kinematicDrive.rotation"),
        ]
        for (drive, name) in cases {
            assertRejected(WorldTransaction().setKinematicDrive(id(2), drive: drive), against: seeded, index: 0,
                           reason: .invalidValue(.nonFiniteValue(name)))
        }
    }

    /// Skończony, ale ogromny napęd silnikowy (np. 3e38) przepełniał `Float` dopiero w kroku; odrzucony przy wejściu.
    func testHugeFiniteMotorDriveIsRejectedAtStaging() throws {
        let seeded = try TransactionStager.stage(resources().add(.rigidBody(box(2, role: .dynamic))), against: state()).state
        let cases: [(MotorDrive, String)] = [
            (try MotorDrive(force: [3e38, 0]), "motor.force"),
            (try MotorDrive(force: [0, -3e38]), "motor.force"),
            (try MotorDrive(torque: 3e38), "motor.torque"),
        ]
        for (drive, name) in cases {
            assertRejected(WorldTransaction().setMotorDrive(id(2), drive: drive), against: seeded, index: 0,
                           reason: .invalidValue(.valueOutOfRange(name)))
        }
        XCTAssertNoThrow(try TransactionStager.stage(WorldTransaction().setMotorDrive(id(2),
            drive: try MotorDrive(force: [1e6, -1e6], torque: 1e6)), against: seeded))
    }
}
