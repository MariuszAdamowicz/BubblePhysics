import BubblePhysicsModel
@testable import BubblePhysicsRuntime
import Metal
import XCTest

@MainActor
final class NativeMetalMotionRoleTests: XCTestCase {
    let ball = ObjectID(rawValue: 1), wall = ObjectID(rawValue: 2)
    /// K_c = 1000 dla „sztywnej” bańki sceny blokad (kulka r 1, m 1, ω = √(K_c / (r · m)) ≈ 32 rad/s); scena blokad bierze też γ = 5, żeby bańka dociśnięta gumką osiadła;
    /// „miękka” to K_c = 229 jak w grze. Kontaktu twardego nie ma: ściana ustępuje o r · ε z prawa K_c · ε / (1 − ε)².
    static let stiffBubbleStiffness: Float = 1000, softBubbleStiffness: Float = 229
    func initial(role: MotionRole = .dynamic, soft: Float = 0, wallAt x: Float? = nil, damping: Float = 0) throws -> RuntimeState {
        var transaction = try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble,
                contactStiffness: soft > 0 ? Self.softBubbleStiffness : Self.stiffBubbleStiffness, damping: damping))
            .updatePhysicsMaterial(.init(rawValue: 2), material: PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: ball, position: .zero, targetRadius: 1, motionRole: role,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1),
                drivePolicy: BubbleDrivePolicy(bandStiffness: 60))))
        if let x {
            transaction = try transaction.add(.rigidBody(RigidBodyDescriptor(id: wall,
                vertices: [[x,-10],[x+0.25,-10],[x+0.25,10],[x,10]],
                physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1))))
        }
        return try TransactionStager.stage(transaction, against: RuntimeState(configuration:
            WorldConfiguration(simulationRegion: WorldRectangle(min: [-50,-50], max: [50,50])))).state
    }
    func step(_ stepper: NativeCompleteStepper, _ state: RuntimeState,
              _ commands: WorldTransaction = WorldTransaction()) async throws -> CompletedRuntimeStep {
        let staged = TransactionStager.stageBatch([PendingTransaction(token: .init(rawValue: 1), transaction: commands)],
            against: state, validate: stepper.validate)
        XCTAssertTrue(staged.frame.events.isEmpty)
        return try await stepper.completePublishedStep(staged, duration: 1.0/60)
    }

    func testBlockedPlayerDriveReportsAchievedPointAndBlockerWithoutTeleporting() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var complete = try await step(stepper, initial(wallAt: 2, damping: 5), WorldTransaction().beginPlayerDrive(ball, target: [8,0]))
        // Gumka K = 60 dociska bańkę do ściany siłą ok. 400. W prawie kontaktu środek nigdy nie dochodzi do czoła ściany (x = 2), a po
        // wytłumieniu (γ = 5, ok. 3 s) stoi w równowadze x = 2 − r · (1 − ε*), gdzie ε* rozwiązuje ε / (1 − ε)² = F / K_c, F = 60 · (8 − x).
        for _ in 0..<200 {
            complete = try await step(stepper, complete.state)
            XCTAssertLessThan(try XCTUnwrap(complete.state.objects[ball]).position.x, 1.9, "środek bańki zbliżył się do czoła ściany")
        }
        let feedback = try XCTUnwrap(complete.driveFeedback.first)
        let rest = try XCTUnwrap(complete.state.objects[ball]).position.x
        var equilibrium = 1.0
        for _ in 0..<60 {   // iteracja stałopunktowa: F zależy od x, x od F
            let force = 60 * (8 - equilibrium)
            equilibrium = 2 - ContactLawReference.equilibriumDistance(force: force, stiffness: Double(Self.stiffBubbleStiffness), radius: 1)
        }
        XCTAssertEqual(Double(rest), equilibrium, accuracy: 0.02)
        XCTAssertEqual(feedback.blockingContact?.objectID, wall)
        XCTAssertGreaterThan(feedback.deviation.x, 6.0)
        XCTAssertEqual(feedback.achievedPoint, complete.state.objects[ball]?.position)
    }

    /// CD-D-10: chwycona gumką bańka dostaje siłę globalną i pola jak `.dynamic`; ścieżka i `.static` ich nie dostają.
    func testDynamicMotorDrivenAndBandPlayerDriveReceiveFieldsWhilePathAndStaticDoNot() async throws {
        for role in [MotionRole.dynamic, .motorDriven, .pathDriven, .playerDriven, .static] {
            let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let field = try ForceFieldDescriptor(id: .init(rawValue: 3), position: .zero,
                geometry: .circle(radius: 20), field: .directional(force: [12,0]))
            var commands = WorldTransaction().add(.forceField(field)).setGlobalForce([0,6])
            if role == .playerDriven { commands = commands.beginPlayerDrive(ball, target: .zero) }
            let complete = try await step(stepper, initial(role: role), commands)
            let velocity = try XCTUnwrap(complete.state.objects[ball]).velocity
            if role == .dynamic || role == .motorDriven || role == .playerDriven {
                XCTAssertEqual(velocity.x, 0.2, accuracy: 0.001)
                XCTAssertEqual(velocity.y, 0.1, accuracy: 0.001)
            } else { XCTAssertEqual(velocity, .zero) }
        }
    }

    func testPathDrivenStopsAtUnresolvableBlocker() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var complete = try await step(stepper, initial(wallAt: 2, damping: 5), WorldTransaction()
            .setPathDrive(ball, drive: PathDrive(points: [[8,0],[8,8]], speed: 6)))
        for _ in 0..<60 { complete = try await step(stepper, complete.state) }
        let feedback = try XCTUnwrap(complete.driveFeedback.first)
        XCTAssertTrue(feedback.isStopped)
        XCTAssertEqual(feedback.blockingContact?.objectID, wall)
        // Tor wciska bańkę w ścianę z prędkością 6 j/s, aż siła kontaktu wyhamuje ją do zatrzymania; zatrzymana bańka (prędkość zero na
        // początku kroku) odpycha się siłą kontaktu do d = r, więc stoi na czole ściany z wgnieceniem poniżej 0,1 % promienia.
        XCTAssertLessThanOrEqual(feedback.achievedPoint.x, 1.001)
        let position = feedback.achievedPoint
        for _ in 0..<5 { complete = try await step(stepper, complete.state) }
        XCTAssertEqual(try XCTUnwrap(complete.state.objects[ball]).position.x, position.x, accuracy: 1e-3)
        XCTAssertLessThanOrEqual(try XCTUnwrap(complete.state.objects[ball]).position.x, position.x)
    }

    func testPlayerDriveAfterStoppedPathReportsOnlyCurrentDriveState() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var complete = try await step(stepper, initial(wallAt: 2, damping: 5), WorldTransaction()
            .setPathDrive(ball, drive: PathDrive(points: [[8,0]], speed: 6)))
        for _ in 0..<60 { complete = try await step(stepper, complete.state) }
        XCTAssertTrue(try XCTUnwrap(complete.driveFeedback.first).isStopped)
        XCTAssertEqual(complete.driveFeedback.first?.blockingContact?.objectID, wall)

        complete = try await step(stepper, complete.state, WorldTransaction().beginPlayerDrive(ball, target: [-8,0]))
        let feedback = try XCTUnwrap(complete.driveFeedback.first)
        XCTAssertEqual(complete.state.objects[ball]?.motionRole, .playerDriven)
        XCTAssertEqual(feedback.target, [-8,0])
        XCTAssertFalse(feedback.isStopped)
        XCTAssertNil(feedback.blockingContact)
    }

    /// G1: chwyt i puszczenie nie zmieniają promienia kolizji ani kształtu: bańka z wgnieceniem z kontaktu zachowuje `targetRadius`
    /// w fizyce także w czasie chwytu (bez usztywniania i bez rozluźniania po puszczeniu).
    func testGrabAndReleaseKeepTheCollisionRadiusAtTheTargetRadius() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        // Initial overlap creates real compression before the grab, not a test-only contour.
        var complete = try await step(stepper, initial(soft: 1, wallAt: 0.7))
        XCTAssertLessThan(try XCTUnwrap(complete.state.objects[ball]).effectiveRadius, 0.99)
        complete = try await step(stepper, complete.state, WorldTransaction().beginPlayerDrive(ball, target: [-3,0]))
        XCTAssertEqual(try XCTUnwrap(complete.state.objects[ball]).collisionRadius, 1, accuracy: 1e-6)
        for _ in 0..<20 {
            complete = try await step(stepper, complete.state)
            XCTAssertEqual(try XCTUnwrap(complete.state.objects[ball]).collisionRadius, 1, accuracy: 1e-6)
        }
        complete = try await step(stepper, complete.state, WorldTransaction().endPlayerDrive(ball))
        XCTAssertEqual(try XCTUnwrap(complete.state.objects[ball]).collisionRadius, 1, accuracy: 1e-6)
    }

    func testMotorForceTorqueAndPhysicalTransitionsAdvanceOnSimulationTime() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let commands = try WorldTransaction().setMotorDrive(ball, drive: MotorDrive(force: [6,0]))
            .startTransition(ParameterTransition(target: .globalForce, value: .vector([0,12]), duration: 1))
            .startTransition(ParameterTransition(target: .bubbleRadius(ball), value: .scalar(2), duration: 1))
            .startTransition(ParameterTransition(target: .physicsMaterial(.init(rawValue: 1), .damping), value: .scalar(0.6), duration: 1))
        let complete = try await step(stepper, initial(), commands)
        XCTAssertEqual(complete.state.globalForce.y, 0.2, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(complete.state.objects[ball]).targetRadius, 1+1.0/60, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(complete.state.physicsMaterials[.init(rawValue: 1)]).damping, 0.01, accuracy: 0.0001)
        XCTAssertGreaterThan(try XCTUnwrap(complete.state.objects[ball]).velocity.x, 0.099)
        let replaced = try await step(stepper, complete.state, WorldTransaction().startTransition(
            ParameterTransition(target: .globalForce, value: .vector([0,-12]), duration: 0)))
        XCTAssertEqual(replaced.state.globalForce, [0,-12])
    }

    /// G4-AC2: bryły nie da się chwycić (`incompatibleObjectKind`); bryłą steruje `MotorDrive`, a moment obrotowy zmienia obrót.
    func testPolygonCannotBeGrabbedAndMotorTorqueChangesRotation() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let polygon = try RigidBodyDescriptor(id: ball, vertices: [[-0.5,-0.5],[0.5,-0.5],[0.5,0.5],[-0.5,0.5]],
            motionRole: .dynamic, physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1))
        let withPolygon = try await step(stepper, initial(wallAt: 2, damping: 5), WorldTransaction().replace(ball, with: .rigidBody(polygon)))
        let rejected = TransactionStager.stageBatch([PendingTransaction(token: .init(rawValue: 2),
            transaction: WorldTransaction().beginPlayerDrive(ball, target: [8,0]))], against: withPolygon.state, validate: stepper.validate)
        XCTAssertEqual(rejected.frame.events, [.transactionRejected(.init(rawValue: 2),
            TransactionRejection(operationIndex: 0, reason: .incompatibleObjectKind(ball)))])
        XCTAssertEqual(rejected.state.objects[ball]?.motionRole, .dynamic)
        let motorStepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let motor = try await step(motorStepper, initial(), WorldTransaction().replace(ball, with: .rigidBody(polygon))
            .setMotorDrive(ball, drive: MotorDrive(force: [6,0], torque: 6)))
        XCTAssertGreaterThan(try XCTUnwrap(motor.state.objects[ball]).rotation, 0)
        // Bez podanego momentu bezwładność liczy się z kształtu: kwadrat 1×1 o masie 1 ma m·(w² + h²)/12 = 1/6.
        XCTAssertEqual(polygon.resolvedMomentOfInertia, 1.0 / 6, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(motor.state.objects[ball]).angularVelocity, 6 / (1.0 / 6) / 60, accuracy: 0.0001)
    }

    func testRadialVortexFalloffAndObjectFilterHavePhysicalEffect() async throws {
        for (field, expected): (ForceField, WorldPoint) in [(.radial(strength: -12, falloff: 1), [-0.1,0]),
                                                            (.vortex(strength: 12, falloff: 1), [0,0.1])] {
            let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            var state = try initial()
            state.objects[ball]?.position = [5,0]; state.objects[ball]?.previousPosition = [5,0]
            let descriptor = try ForceFieldDescriptor(id: .init(rawValue: 3), position: .zero,
                geometry: .circle(radius: 10), field: field, filter: ObjectFilter(objectIDs: [ball]))
            let complete = try await step(stepper, state, WorldTransaction().add(.forceField(descriptor)))
            let velocity = try XCTUnwrap(complete.state.objects[ball]).velocity
            XCTAssertEqual(velocity.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(velocity.y, expected.y, accuracy: 0.0001)
        }
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let excluded = try ForceFieldDescriptor(id: .init(rawValue: 3), position: .zero,
            geometry: .circle(radius: 10), field: .directional(force: [100,100]),
            filter: ObjectFilter(objectIDs: []))
        let complete = try await step(stepper, initial(), WorldTransaction().add(.forceField(excluded)))
        XCTAssertEqual(complete.state.objects[ball]?.velocity, .zero)
    }
}
