import BubblePhysicsModel
@testable import BubblePhysicsNativeMetal
import XCTest

/// Rekordy sił silnika 4.0.0 (plan, zadanie 6): host przekazuje GPU gumkę, siłę globalną, opisy pól z filtrami, motor i pozy brył
/// kinematycznych jako dane wejściowe kroku (CD-D-5). Tu tylko zawartość rekordów budowanych z obiektów świata; ich użycie w
/// podkrokach dodają kolejne zadania.
final class NativeForceRecordsTests: XCTestCase {
    private let physics = PhysicsMaterialID(rawValue: 1), style = RenderMaterialID(rawValue: 1)

    private func bubble(_ id: UInt64, at position: WorldPoint = .zero, role: MotionRole, mass: Float = 2, radius: Float = 4,
                        policy: BubbleDrivePolicy? = nil) throws -> NativePublicObject {
        var object = NativePublicObject(descriptor: .bubble(try BubbleDescriptor(id: ObjectID(rawValue: id), position: position,
            targetRadius: radius, mass: mass, motionRole: role, physicsMaterialID: physics, renderMaterialID: style,
            drivePolicy: policy)))
        object.collisionRadius = radius
        return object
    }

    private func field(_ id: UInt64, _ field: ForceField, shape: RangeGeometry.Shape = .circle(radius: 100),
                       at position: WorldPoint = .zero, rotation: Float = 0, filter: Set<ObjectID>? = nil) throws -> NativePublicObject {
        NativePublicObject(descriptor: .forceField(try ForceFieldDescriptor(id: ObjectID(rawValue: id), position: position,
            rotation: rotation, geometry: RangeGeometry(shape: shape), field: field, filter: ObjectFilter(objectIDs: filter))))
    }

    func testEmptyWorldHasNoForceRecords() {
        let input = NativeForceInput(objects: [], globalForce: [3, -4])
        XCTAssertEqual(input.globalForce, [3, -4])
        XCTAssertTrue(input.bandDrives.isEmpty)
        XCTAssertTrue(input.fields.isEmpty)
        XCTAssertTrue(input.motors.isEmpty)
        XCTAssertTrue(input.kinematicPoses.isEmpty)
    }

    // G4-AC4: gumka niesie cel, K_band i opcjonalny `maximumForce` (0 = bez limitu); bańka bez celu albo polityki nie ma gumki.
    func testBandRecordCarriesTargetStiffnessAndOptionalMaximumForce() throws {
        var limited = try bubble(7, role: .playerDriven, policy: BubbleDrivePolicy(bandStiffness: 22, maximumForce: 250))
        limited.playerDriveTarget = [3, 4]
        var unlimited = try bubble(2, role: .playerDriven, policy: BubbleDrivePolicy(bandStiffness: 100))
        unlimited.playerDriveTarget = [-5, 6]
        var withoutTarget = try bubble(3, role: .playerDriven, policy: BubbleDrivePolicy(bandStiffness: 100))
        withoutTarget.playerDriveTarget = nil
        var withoutPolicy = try bubble(4, role: .playerDriven)
        withoutPolicy.playerDriveTarget = [1, 1]
        var dynamic = try bubble(5, role: .dynamic, policy: BubbleDrivePolicy(bandStiffness: 100))
        dynamic.playerDriveTarget = [1, 1]
        let input = NativeForceInput(objects: [limited, unlimited, withoutTarget, withoutPolicy, dynamic], globalForce: .zero)
        XCTAssertEqual(input.bandDrives, [
            NativeMetalBandDrive(identity: SIMD2(2, 0), band: SIMD4(-5, 6, 100, 0)),
            NativeMetalBandDrive(identity: SIMD2(7, 0), band: SIMD4(3, 4, 22, 250))], "po ID, tylko role .playerDriven z celem i polityką")
    }

    // G4-AC5: motor niesie siłę, moment i bezwładność ½ m r² bańki.
    func testMotorRecordCarriesForceTorqueAndBubbleInertia() throws {
        var motor = try bubble(9, role: .motorDriven, mass: 2, radius: 3)
        motor.motorDrive = try MotorDrive(force: [5, -6], torque: 7)
        var idle = try bubble(8, role: .motorDriven)
        idle.motorDrive = nil
        var notMotor = try bubble(6, role: .dynamic)
        notMotor.motorDrive = try MotorDrive(force: [1, 1], torque: 1)
        let input = NativeForceInput(objects: [motor, idle, notMotor], globalForce: .zero)
        XCTAssertEqual(input.motors, [NativeMetalMotor(identity: SIMD2(9, 0), drive: SIMD4(5, -6, 7, 0.5 * 2 * 3 * 3))])
    }

    // G4-AC5: pola z filtrem obiektów; pola idą po ID, a filtr to zakres w osobnej tablicy identyfikatorów.
    func testFieldRecordsCarryKindPoseStrengthRadiusAndObjectFilter() throws {
        let directional = try field(20, .directional(force: [0, 40]), at: [1, 2], rotation: 0.5,
                                    filter: [ObjectID(rawValue: 9), ObjectID(rawValue: 3)])
        let radial = try field(10, .radial(strength: -500, falloff: 2), shape: .circle(radius: 400), at: [10, 20])
        let vortex = try field(30, .vortex(strength: 7, falloff: 0), at: [0, 0], filter: [])
        let input = NativeForceInput(objects: [directional, radial, vortex], globalForce: .zero)
        XCTAssertEqual(input.fields.map(\.identity.x), [10, 20, 30])
        let r = input.fields[0], d = input.fields[1], v = input.fields[2]
        XCTAssertEqual(r.shape.x, NativeMetalForceField.radialKind)
        XCTAssertEqual(r.pose, SIMD4(10, 20, 0, 2), "położenie, obrót, falloff")
        XCTAssertEqual(r.strength, SIMD4(0, 0, -500, 400), "bez siły kierunkowej, siła radialna, promień zasięgu")
        XCTAssertEqual(r.shape.z, 0, "koło nie ma wierzchołków")
        XCTAssertEqual(r.filter.z, 0, "bez filtra obiektów")
        XCTAssertEqual(d.shape.x, NativeMetalForceField.directionalKind)
        XCTAssertEqual(d.pose, SIMD4(1, 2, 0.5, 0))
        XCTAssertEqual(d.strength, SIMD4(0, 40, 0, 100))
        XCTAssertEqual(d.filter.z, 1)
        XCTAssertEqual(d.filter.y, 2)
        XCTAssertEqual(Array(input.fieldObjectIDs[Int(d.filter.x)..<Int(d.filter.x + d.filter.y)]), [3, 9], "identyfikatory rosnąco")
        XCTAssertEqual(v.shape.x, NativeMetalForceField.vortexKind)
        XCTAssertEqual(v.filter.z, 1, "pusty filtr jest filtrem: pole nie działa na nikogo")
        XCTAssertEqual(v.filter.y, 0)
    }

    func testPolygonFieldRecordPointsAtItsVerticesAndUsesTheFarthestVertexAsRange() throws {
        let square: RangeGeometry.Shape = .polygon(try PolygonGeometry(vertices: [[-3, -4], [3, -4], [3, 4], [-3, 4]]))
        let other: RangeGeometry.Shape = .polygon(try PolygonGeometry(vertices: [[0, 0], [10, 0], [0, 10]]))
        let input = NativeForceInput(objects: [try field(1, .directional(force: [1, 0]), shape: square),
                                               try field(2, .radial(strength: 1, falloff: 1), shape: other)], globalForce: .zero)
        let first = input.fields[0], second = input.fields[1]
        XCTAssertEqual(first.shape.z, 4)
        XCTAssertEqual(second.shape.z, 3)
        XCTAssertEqual(first.strength.w, 5, "najdalszy wierzchołek (3, 4)")
        XCTAssertEqual(second.strength.w, 10)
        XCTAssertEqual(Array(input.fieldVertices[Int(first.shape.y)..<Int(first.shape.y + first.shape.z)]),
                       [[-3, -4], [3, -4], [3, 4], [-3, 4]])
        XCTAssertEqual(Array(input.fieldVertices[Int(second.shape.y)..<Int(second.shape.y + second.shape.z)]),
                       [[0, 0], [10, 0], [0, 10]])
    }

    // G3-AC3: poza kinematyczna na początku kroku i prędkość liniowa i kątowa; tylko brył w roli `.kinematic`.
    func testKinematicPoseRecordCarriesStartPoseAndVelocities() throws {
        func body(_ id: UInt64, role: MotionRole) throws -> NativePublicObject {
            var object = NativePublicObject(descriptor: .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: id),
                vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], motionRole: role, physicsMaterialID: physics, renderMaterialID: style)))
            object.position = [100, 360]; object.rotation = 0.25; object.velocity = [1000, -5]; object.angularVelocity = 20
            return object
        }
        let input = NativeForceInput(objects: [try body(5, role: .kinematic), try body(4, role: .static), try body(3, role: .dynamic)],
                                     globalForce: .zero)
        XCTAssertEqual(input.kinematicPoses, [NativeMetalKinematicPose(identity: SIMD2(5, 0), pose: SIMD4(100, 360, 0.25, 0),
                                                                       velocity: SIMD4(1000, -5, 20, 0))])
    }

    // Rekord bańki niesie K_c, a oznaczenie bańki napędzanej siłami (siła globalna, pola, γ) nie obejmuje ról torowych.
    func testBubbleContactRecordCarriesStiffnessAndForceDrivenFlag() {
        let transitional = NativePublicProperties.contact(stiffness: 5, radius: 20, forceDriven: true)
        XCTAssertEqual(transitional, SIMD4(4, 5, 1, 1), "podatność przejściowa, K_c, ζ_c, bańka napędzana siłami")
        XCTAssertEqual(NativePublicProperties.contact(stiffness: 5, radius: 20, forceDriven: false).w, 0)
        XCTAssertEqual(NativePublicProperties.contact(stiffness: 229, radius: 24, forceDriven: true).y, 229)
        XCTAssertEqual(NativePublicProperties.contact(stiffness: nil, radius: 5, forceDriven: true), SIMD4(0, 0, 1, 1))
        for role in [MotionRole.dynamic, .motorDriven, .playerDriven] { XCTAssertTrue(NativePublicProperties.isForceDriven(role), "\(role)") }
        for role in [MotionRole.static, .kinematic, .pathDriven] { XCTAssertFalse(NativePublicProperties.isForceDriven(role), "\(role)") }
    }

    // Rekord sterowania podkrokami zaczyna od zera i ma układ z shadera.
    func testSubstepControlStartsZeroed() {
        let control = NativeMetalSubstepControl()
        XCTAssertEqual(control.time, .zero)
        XCTAssertEqual(control.counts, .zero)
        XCTAssertEqual(control.limiter, .zero)
    }
}
