import BubblePhysics
@testable import BubblePhysicsRuntime
import Metal
import XCTest

@MainActor
final class RegionPolicyTests: XCTestCase {
    func testCircleOutsideCornerIsRemovedEvenWhenItsBoundsOverlapRegion() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .remove)
        state.objects[.init(rawValue: 1)]?.position = [10.8, 10.8]
        state.objects[.init(rawValue: 1)]?.velocity = .zero
        let complete = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25)
        XCTAssertTrue(complete.state.objects.isEmpty)
    }

    func testWrapRetainsOvershootAcrossSeveralRegionWidths() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .wrap)
        state.objects[.init(rawValue: 1)]?.position = [-25, 5]
        state.objects[.init(rawValue: 1)]?.velocity = [-4, 0]
        let complete = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25)
        let object = try XCTUnwrap(complete.state.objects[.init(rawValue: 1)])
        XCTAssertEqual(object.position, [10, 5])
        XCTAssertEqual(object.previousPosition, [11, 5])
        XCTAssertEqual(object.velocity, [-4, 0])
    }

    func testUnsupportedDynamicPolygonsAreRejectedAtomicallyInsteadOfStallingWorld() async throws {
        for role in [MotionRole.dynamic, .motorDriven] {
            let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
            let token = world.submit(try WorldTransaction()
                .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
                .updatePhysicsMaterial(.init(rawValue: 2), material: PhysicsMaterial(kind: .polygon))
                .add(.polygon(PolygonDescriptor(id: .init(rawValue: 3), vertices: [[0, 0], [1, 0], [0, 1]],
                    position: [3, 3], motionRole: role, physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1)))))
            let frame = await world.advance(by: 0.25)
            XCTAssertEqual(frame.stepIndex, 1)
            XCTAssertTrue(frame.transactionReceipts.isEmpty)
            XCTAssertEqual(frame.events.count, 1)
            if case .transactionRejected(let rejected, let reason) = frame.events.first {
                XCTAssertEqual(rejected, token)
                XCTAssertEqual(reason.operationIndex, 2)
                XCTAssertEqual(reason.reason, .unsupportedMotionRole(.init(rawValue: 3), role))
            } else { XCTFail("Expected structured unsupported-role rejection") }
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        }
    }

    func testUnsupportedMaterialPropertiesAreRejectedBeforePublication() async throws {
        for material in [try PhysicsMaterial(kind: .bubble, friction: 0.5),
                         try PhysicsMaterial(kind: .bubble, restitution: 0.5),
                         try PhysicsMaterial(kind: .bubble, deformability: 0.5)] {
            let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
            world.submit(WorldTransaction().updatePhysicsMaterial(.init(rawValue: 1), material: material))
            let frame = await world.advance(by: 0.25)
            XCTAssertEqual(frame.stepIndex, 1)
            XCTAssertTrue(frame.transactionReceipts.isEmpty)
            XCTAssertEqual(frame.events.count, 1)
            if case .transactionRejected(_, let rejection) = frame.events.first {
                XCTAssertEqual(rejection.reason, .unsupportedPhysicsParameter(.init(rawValue: 1),
                    material.friction != 0 ? .friction : (material.restitution != 0 ? .restitution : .deformability)))
            }
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        }
    }

    func testRemovalWaitsUntilEntireColliderLeavesRegion() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .remove)
        state.transitions[.bubbleRadius(.init(rawValue: 1))] = ParameterTransition(
            target: .bubbleRadius(.init(rawValue: 1)), value: .scalar(0.5), duration: 10)
        for expectedX: Float in [10, 11] {
            state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
            XCTAssertEqual(try XCTUnwrap(state.objects[.init(rawValue: 1)]).position.x, expectedX, accuracy: 0.0001)
        }
        state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        XCTAssertNil(state.objects[.init(rawValue: 1)])
        XCTAssertTrue(state.transitions.isEmpty)
    }

    func testWrapPreservesVelocityAndDoesNotCreateSeamContact() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .wrap)
        // Opposite-edge bubble overlaps only a toroidal image, never the real collider.
        let other = try BubbleDescriptor(id: .init(rawValue: 2), position: [0.25, 5], targetRadius: 1,
            physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))
        state = try TransactionStager.stage(WorldTransaction().add(.bubble(other)), against: state).state
        state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        XCTAssertEqual(try XCTUnwrap(state.objects[other.id]).position.x, 0.25, accuracy: 0.0001)
        for _ in 0..<2 {
            state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        }
        let wrapped = try XCTUnwrap(state.objects[.init(rawValue: 1)])
        XCTAssertEqual(wrapped.position.x, 0, accuracy: 0.0001)
        XCTAssertEqual(wrapped.previousPosition.x, -1, accuracy: 0.0001)
        XCTAssertEqual(wrapped.velocity, [4, 0])
    }

    func testPublicWorldUsesNativeRegionPolicy() async throws {
        let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
        let state = try initial(policy: .remove)
        let object = try XCTUnwrap(state.objects[.init(rawValue: 1)])
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: RenderStyle()).add(object.descriptor))
        _ = await world.advance(by: 0.75)
        let token = world.submit(WorldTransaction().remove(.init(rawValue: 1)))
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.events, [.transactionRejected(token, TransactionRejection(operationIndex: 0,
            reason: .objectNotFound(.init(rawValue: 1))))])
    }

    private func initial(policy: RegionExitPolicy) throws -> RuntimeState {
        let state = RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [0, 0], max: [10, 10]), fixedTimeStep: 0.25))
        return try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
            .add(.bubble(BubbleDescriptor(id: .init(rawValue: 1), position: [9, 5], velocity: [4, 0],
                targetRadius: 1, regionExitPolicy: policy, physicsMaterialID: .init(rawValue: 1),
                renderStyleID: .init(rawValue: 1)))), against: state).state
    }
}
