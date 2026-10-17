import BubblePhysicsModel
@testable import BubblePhysicsRuntime
import Metal
import XCTest

@MainActor
final class NativeMetalMotionRoleTests: XCTestCase {
    let ball = ObjectID(rawValue: 1), wall = ObjectID(rawValue: 2)
    func initial(role: MotionRole = .dynamic, soft: Float = 0, wallAt x: Float? = nil) throws -> RuntimeState {
        var transaction = try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble, deformability: soft))
            .updatePhysicsMaterial(.init(rawValue: 2), material: PhysicsMaterial(kind: .polygon))
            .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
            .add(.bubble(BubbleDescriptor(id: ball, position: .zero, targetRadius: 1, motionRole: role,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        if let x {
            transaction = try transaction.add(.polygon(PolygonDescriptor(id: wall,
                vertices: [[x,-10],[x+0.25,-10],[x+0.25,10],[x,10]],
                physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1))))
        }
        return try TransactionStager.stage(transaction, against: RuntimeState(configuration:
            WorldConfiguration(simulationRegion: WorldRectangle(min: [-50,-50], max: [50,50])))).state
    }
    func step(_ stepper: NativeCompleteStepper, _ state: RuntimeState,
              _ commands: WorldTransaction = WorldTransaction()) async throws -> CompletedRuntimeStep {
        let staged = TransactionStager.stageBatch([PendingTransaction(token: .init(rawValue: 1), transaction: commands)],
            against: state, validate: stepper.validate)
        XCTAssertTrue(staged.frame.events.isEmpty)
        return try await stepper.completeStep(staged, duration: 1.0/60)
    }

    func testBlockedPlayerDriveReportsAchievedPointAndBlockerWithoutTeleporting() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var complete = try await step(stepper, initial(wallAt: 2), WorldTransaction().beginPlayerDrive(ball, target: [8,0]))
        for _ in 0..<40 {
            complete = try await step(stepper, complete.state)
            XCTAssertLessThanOrEqual(try XCTUnwrap(complete.state.objects[ball]).position.x, 1.001)
        }
        let feedback = try XCTUnwrap(complete.driveFeedback.first)
        XCTAssertEqual(feedback.blockingContact?.objectID, wall)
        XCTAssertGreaterThan(feedback.deviation.x, 6.9)
        XCTAssertEqual(feedback.achievedPoint, complete.state.objects[ball]?.position)
    }

    func testDynamicAndMotorDrivenReceiveFieldsWhileActivePlayerDriveDoesNot() async throws {
        for role in [MotionRole.dynamic, .motorDriven, .pathDriven, .playerDriven, .static] {
            let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let field = try ForceFieldDescriptor(id: .init(rawValue: 3), position: .zero,
                geometry: .circle(radius: 20), field: .directional(force: [12,0]), renderStyleID: .init(rawValue: 1))
            var commands = WorldTransaction().add(.forceField(field)).setGlobalForce([0,6])
            if role == .playerDriven { commands = commands.beginPlayerDrive(ball, target: .zero) }
            let complete = try await step(stepper, initial(role: role), commands)
            let velocity = try XCTUnwrap(complete.state.objects[ball]).velocity
            if role == .dynamic || role == .motorDriven {
                XCTAssertEqual(velocity.x, 0.2, accuracy: 0.001)
                XCTAssertEqual(velocity.y, 0.1, accuracy: 0.001)
            } else { XCTAssertEqual(velocity, .zero) }
        }
    }

    func testPathDrivenStopsAtUnresolvableBlocker() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var complete = try await step(stepper, initial(wallAt: 2), WorldTransaction()
            .setPathDrive(ball, drive: PathDrive(points: [[8,0],[8,8]], speed: 6)))
        for _ in 0..<35 { complete = try await step(stepper, complete.state) }
        let feedback = try XCTUnwrap(complete.driveFeedback.first)
        XCTAssertTrue(feedback.isStopped)
        XCTAssertEqual(feedback.blockingContact?.objectID, wall)
        XCTAssertLessThanOrEqual(feedback.achievedPoint.x, 1.001)
        let position = feedback.achievedPoint
        for _ in 0..<5 { complete = try await step(stepper, complete.state) }
        XCTAssertEqual(complete.state.objects[ball]?.position, position)
    }

    func testPlayerDriveAfterStoppedPathReportsOnlyCurrentDriveState() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var complete = try await step(stepper, initial(wallAt: 2), WorldTransaction()
            .setPathDrive(ball, drive: PathDrive(points: [[8,0]], speed: 6)))
        for _ in 0..<35 { complete = try await step(stepper, complete.state) }
        XCTAssertTrue(try XCTUnwrap(complete.driveFeedback.first).isStopped)
        XCTAssertEqual(complete.driveFeedback.first?.blockingContact?.objectID, wall)

        complete = try await step(stepper, complete.state, WorldTransaction().beginPlayerDrive(ball, target: [-8,0]))
        let feedback = try XCTUnwrap(complete.driveFeedback.first)
        XCTAssertEqual(complete.state.objects[ball]?.motionRole, .playerDriven)
        XCTAssertEqual(feedback.target, [-8,0])
        XCTAssertFalse(feedback.isStopped)
        XCTAssertNil(feedback.blockingContact)
    }

    func testPlayerDrivenBubbleTransitionsToEffectiveRigidCircleThenRelaxesAfterRelease() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        // Initial overlap creates real compression before capture, not a test-only contour.
        var complete = try await step(stepper, initial(soft: 1, wallAt: 0.7))
        let radius = try XCTUnwrap(complete.state.objects[ball]).effectiveRadius
        XCTAssertLessThan(radius, 0.99)
        complete = try await step(stepper, complete.state, WorldTransaction()
            .beginPlayerDrive(ball, target: [-3,0]))
        let first = try XCTUnwrap(complete.state.objects[ball])
        XCTAssertGreaterThan(first.collisionRadius, radius)
        XCTAssertLessThan(first.collisionRadius, 1)
        for _ in 0..<20 { complete = try await step(stepper, complete.state) }
        XCTAssertEqual(try XCTUnwrap(complete.state.objects[ball]).collisionRadius, radius, accuracy: 0.001)
        complete = try await step(stepper, complete.state, WorldTransaction().endPlayerDrive(ball))
        XCTAssertGreaterThan(try XCTUnwrap(complete.state.objects[ball]).collisionRadius, radius)
        XCTAssertLessThan(try XCTUnwrap(complete.state.objects[ball]).collisionRadius, 1)
        for _ in 0..<30 { complete = try await step(stepper, complete.state) }
        XCTAssertEqual(try XCTUnwrap(complete.state.objects[ball]).collisionRadius, 1, accuracy: 0.001)
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

    func testPlayerDrivenPolygonReportsWallAndMotorTorqueChangesRotation() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let polygon = try PolygonDescriptor(id: ball, vertices: [[-0.5,-0.5],[0.5,-0.5],[0.5,0.5],[-0.5,0.5]],
            motionRole: .dynamic, physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1))
        var complete = try await step(stepper, initial(wallAt: 2), WorldTransaction()
            .replace(ball, with: .polygon(polygon)).beginPlayerDrive(ball, target: [8,0]))
        for _ in 0..<60 { complete = try await step(stepper, complete.state) }
        XCTAssertEqual(complete.driveFeedback.first?.blockingContact?.objectID, wall)
        XCTAssertLessThanOrEqual(try XCTUnwrap(complete.state.objects[ball]).position.x, 1.501)
        let motorStepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let motor = try await step(motorStepper, initial(), WorldTransaction().replace(ball, with: .polygon(polygon))
            .setMotorDrive(ball, drive: MotorDrive(force: [6,0], torque: 6)))
        XCTAssertGreaterThan(try XCTUnwrap(motor.state.objects[ball]).rotation, 0)
        XCTAssertEqual(try XCTUnwrap(motor.state.objects[ball]).angularVelocity, 0.1, accuracy: 0.0001)
    }

    func testRadialVortexFalloffAndObjectFilterHavePhysicalEffect() async throws {
        for (field, expected): (ForceField, WorldPoint) in [(.radial(strength: -12, falloff: 1), [-0.1,0]),
                                                            (.vortex(strength: 12, falloff: 1), [0,0.1])] {
            let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            var state = try initial()
            state.objects[ball]?.position = [5,0]; state.objects[ball]?.previousPosition = [5,0]
            let descriptor = try ForceFieldDescriptor(id: .init(rawValue: 3), position: .zero,
                geometry: .circle(radius: 10), field: field, filter: ObjectFilter(objectIDs: [ball]),
                renderStyleID: .init(rawValue: 1))
            let complete = try await step(stepper, state, WorldTransaction().add(.forceField(descriptor)))
            let velocity = try XCTUnwrap(complete.state.objects[ball]).velocity
            XCTAssertEqual(velocity.x, expected.x, accuracy: 0.0001)
            XCTAssertEqual(velocity.y, expected.y, accuracy: 0.0001)
        }
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let excluded = try ForceFieldDescriptor(id: .init(rawValue: 3), position: .zero,
            geometry: .circle(radius: 10), field: .directional(force: [100,100]),
            filter: ObjectFilter(objectIDs: []), renderStyleID: .init(rawValue: 1))
        let complete = try await step(stepper, initial(), WorldTransaction().add(.forceField(excluded)))
        XCTAssertEqual(complete.state.objects[ball]?.velocity, .zero)
    }
}
