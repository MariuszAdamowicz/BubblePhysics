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

    func testDiagonalCornerWrapReentersRegionAndDoesNotOscillate() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .wrap)
        state.objects[.init(rawValue: 1)]?.position = [10.8, 10.8]
        state.objects[.init(rawValue: 1)]?.velocity = .zero
        state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        let wrapped = try XCTUnwrap(state.objects[.init(rawValue: 1)])
        let dx = max(0, max(-wrapped.position.x, wrapped.position.x - 10))
        let dy = max(0, max(-wrapped.position.y, wrapped.position.y - 10))
        XCTAssertLessThanOrEqual(sqrt(dx * dx + dy * dy), 1)
        state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        let next = try XCTUnwrap(state.objects[.init(rawValue: 1)])
        XCTAssertEqual(next.position.x, wrapped.position.x, accuracy: 0.0001)
        XCTAssertEqual(next.position.y, wrapped.position.y, accuracy: 0.0001)
        XCTAssertEqual(next.velocity, .zero)
    }

    func testDrivenPolygonDescriptorsAreAcceptedWithoutStallingWorld() async throws {
        for role in [MotionRole.pathDriven, .playerDriven] {
            let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
            world.submit(try WorldTransaction()
                .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
                .updatePhysicsMaterial(.init(rawValue: 2), material: PhysicsMaterial(kind: .polygon))
                .add(.polygon(PolygonDescriptor(id: .init(rawValue: 3), vertices: [[0, 0], [1, 0], [0, 1]],
                    position: [3, 3], motionRole: role, physicsMaterialID: .init(rawValue: 2), renderStyleID: .init(rawValue: 1)))))
            let frame = await world.advance(by: 0.25)
            XCTAssertEqual(frame.stepIndex, 1)
            XCTAssertEqual(frame.transactionReceipts.count, 1)
            XCTAssertTrue(frame.events.isEmpty)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        }
    }

    func testMaterialContactPropertiesAreAcceptedAndPublished() async throws {
        for material in [try PhysicsMaterial(kind: .bubble, friction: 0.5),
                         try PhysicsMaterial(kind: .bubble, restitution: 0.5)] {
            let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
            let token = world.submit(WorldTransaction().updatePhysicsMaterial(.init(rawValue: 1), material: material))
            let frame = await world.advance(by: 0.25)
            XCTAssertEqual(frame.stepIndex, 1)
            XCTAssertEqual(frame.transactionReceipts.map(\.token), [token])
            XCTAssertTrue(frame.events.isEmpty)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)

            let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let pending = PendingTransaction(token: .init(rawValue: 1), transaction:
                WorldTransaction().updatePhysicsMaterial(.init(rawValue: 1), material: material))
            let complete = try await stepper.completeStep(TransactionStager.stageBatch([pending], against: initial(policy: .remove)), duration: 0.25)
            XCTAssertEqual(complete.state.physicsMaterials[.init(rawValue: 1)], material)
        }
    }

    func testUnsupportedMergeResultRoleIsRejectedWithoutRetryingFrame() async throws {
        let world = try await seededWorld()
        let token = world.submit(WorldTransaction().mergeBubbles([.init(rawValue: 1), .init(rawValue: 2)],
            result: BubbleResult(id: .init(rawValue: 3), physicsMaterialID: .init(rawValue: 1),
                renderStyleID: .init(rawValue: 1), motionRole: .motorDriven)))
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.stepIndex, 2)
        XCTAssertEqual(frame.events, [.transactionRejected(token, TransactionRejection(operationIndex: 0,
            reason: .unsupportedMotionRole(.init(rawValue: 3), .motorDriven)))])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    func testUnsupportedSplitResultRoleIsRejectedWithoutRetryingFrame() async throws {
        let world = try await seededWorld()
        let first = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 3),
            physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1)), share: 0.5)
        let second = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 4),
            physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1), motionRole: .pathDriven), share: 0.5)
        let token = world.submit(WorldTransaction().splitBubble(.init(rawValue: 1), first: first, second: second))
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.stepIndex, 2)
        XCTAssertEqual(frame.events, [.transactionRejected(token, TransactionRejection(operationIndex: 0,
            reason: .unsupportedMotionRole(.init(rawValue: 4), .pathDriven)))])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    func testMaterialContactTransitionsAreAcceptedAndAdvancePublishedValue() async throws {
        for parameter in [PhysicsParameter.friction, .restitution] {
            let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
            let token = world.submit(try WorldTransaction()
                .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
                .startTransition(ParameterTransition(target: .physicsMaterial(.init(rawValue: 1), parameter),
                    value: .scalar(0.5), duration: 1)))
            let frame = await world.advance(by: 0.25)
            XCTAssertEqual(frame.stepIndex, 1)
            XCTAssertEqual(frame.transactionReceipts.map(\.token), [token])
            XCTAssertTrue(frame.events.isEmpty)
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)

            let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            let transaction = try WorldTransaction()
                .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
                .startTransition(ParameterTransition(target: .physicsMaterial(.init(rawValue: 1), parameter),
                    value: .scalar(0.5), duration: 1))
            let complete = try await stepper.completeStep(TransactionStager.stageBatch([
                .init(token: .init(rawValue: 1), transaction: transaction)
            ], against: initial(policy: .remove)), duration: 0.25)
            let material = try XCTUnwrap(complete.state.physicsMaterials[.init(rawValue: 1)])
            XCTAssertEqual(parameter == .friction ? material.friction : material.restitution, 0.125, accuracy: 0.0001)
        }
    }

    func testRemovalUsesTransitioningColliderAndCleansTransitionProgress() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .remove)
        state.transitions[.bubbleRadius(.init(rawValue: 1))] = ParameterTransition(
            target: .bubbleRadius(.init(rawValue: 1)), value: .scalar(0.5), duration: 10)
        state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        XCTAssertEqual(try XCTUnwrap(state.objects[.init(rawValue: 1)]).position.x, 10, accuracy: 0.0001)
        // Po drugim kroku x=11, promień=0.975: cały collider opuścił region.
        state = try await stepper.completeStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        XCTAssertNil(state.objects[.init(rawValue: 1)])
        XCTAssertTrue(state.transitions.isEmpty)
        XCTAssertTrue(state.transitionProgress.isEmpty)
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

    private func seededWorld() async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
        let transaction = try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
            .add(.bubble(BubbleDescriptor(id: .init(rawValue: 1), position: [3, 3], targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
            .add(.bubble(BubbleDescriptor(id: .init(rawValue: 2), position: [7, 3], targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1))))
        world.submit(transaction)
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.stepIndex, 1)
        return world
    }
}
