import BubblePhysics
@testable import BubblePhysicsRuntime
import Metal
import XCTest
import simd

@MainActor
final class RegionPolicyTests: XCTestCase {
    func testCircleOutsideCornerIsRemovedEvenWhenItsBoundsOverlapRegion() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .remove)
        state.objects[.init(rawValue: 1)]?.position = [10.8, 10.8]
        state.objects[.init(rawValue: 1)]?.velocity = .zero
        let complete = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25)
        XCTAssertTrue(complete.state.objects.isEmpty)
    }

    // P-B-67: obiekt usunięty po wyjściu z regionu zabiera swoje więzy, a więzy innych ciał zostają.
    func testRemoveDropsJointsOfRemovedObjectsOnly() throws {
        var state = try initial(policy: .remove)
        func joint(_ id: UInt64, _ a: UInt64, _ b: UInt64?) throws -> Joint {
            try Joint(id: JointID(rawValue: id), bodyA: ObjectID(rawValue: a), bodyB: b.map { ObjectID(rawValue: $0) },
                      kind: .distance(length: 1, softness: 0, damping: 0))
        }
        for value in [try joint(1, 1, nil), try joint(2, 1, 2), try joint(3, 2, 3), try joint(4, 3, nil)] { state.joints[value.id] = value }
        RegionPolicy.remove([ObjectID(rawValue: 1)], from: &state)
        XCTAssertEqual(Set(state.joints.keys), [JointID(rawValue: 3), JointID(rawValue: 4)])
    }

    // P-B-67 na kroku GPU: bańka z więzem opuszcza region, więz znika ze stanu, a partner zostaje.
    func testStepRemovesJointOfObjectThatLeftRegion() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .remove)
        state = try TransactionStager.stage(WorldTransaction()
            .add(.bubble(BubbleDescriptor(id: .init(rawValue: 2), position: [5, 8], targetRadius: 1,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1))))
            // Długość równa odległości środków (10,8 – 5, 8 do rogu), więc więz niczego nie przesuwa przed wyjściem.
            .addJoint(Joint(id: JointID(rawValue: 7), bodyA: .init(rawValue: 1), bodyB: .init(rawValue: 2),
                            kind: .distance(length: simd_distance(WorldPoint(10.8, 10.8), WorldPoint(5, 8)),
                                            softness: 0, damping: 0))), against: state).state
        state.objects[.init(rawValue: 1)]?.position = [10.8, 10.8]
        state.objects[.init(rawValue: 1)]?.velocity = .zero
        XCTAssertEqual(state.joints.count, 1)
        let complete = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25)
        XCTAssertNil(complete.state.objects[.init(rawValue: 1)])
        XCTAssertNotNil(complete.state.objects[.init(rawValue: 2)])
        XCTAssertTrue(complete.state.joints.isEmpty)
    }

    // P-B-52: zawinięcie trafia do zbioru obiektów rysowanych bez interpolacji, choć gra nie prosi o `didWrap`.
    func testWrappedObjectIsSnappedEvenWithoutDidWrapInterest() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .wrap)
        state.objects[.init(rawValue: 1)]?.position = [-25, 5]
        state.objects[.init(rawValue: 1)]?.velocity = [-4, 0]
        let complete = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25)
        XCTAssertEqual(complete.snappedObjectIDs, [.init(rawValue: 1)])
        XCTAssertTrue(complete.events.isEmpty, "bez zainteresowania didWrap nie ma zdarzenia")
    }

    func testStepWithoutWrapsAndOperationsSnapsNothing() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let state = try initial(policy: .wrap)
        let complete = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.001)
        XCTAssertTrue(complete.snappedObjectIDs.isEmpty)
    }

    // P-B-52: obiekty utworzone, zastąpione, scalone i podzielone w partii rysują się bez interpolacji.
    func testBatchOperationsSnapCreatedReplacedMergedAndSplitObjects() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        func bubble(_ id: UInt64, _ x: Float) throws -> WorldObject {
            .bubble(try BubbleDescriptor(id: .init(rawValue: id), position: [x, 5], targetRadius: 1, regionExitPolicy: .wrap,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)))
        }
        let state = try initial(policy: .wrap)
        func pending(_ transaction: WorldTransaction) -> PendingTransaction {
            PendingTransaction(token: .init(rawValue: 1), transaction: transaction)
        }
        var batch = TransactionStager.stageBatch([pending(try WorldTransaction().add(bubble(2, 3)).add(bubble(3, 5.5)))],
                                                 against: state)
        var step = try await stepper.completePublishedStep(batch, duration: 0.001)
        XCTAssertEqual(step.snappedObjectIDs, [.init(rawValue: 2), .init(rawValue: 3)], "utworzone")
        batch = TransactionStager.stageBatch([pending(try WorldTransaction().replace(.init(rawValue: 2), with: bubble(2, 2)))],
                                             against: step.state)
        step = try await stepper.completePublishedStep(batch, duration: 0.001)
        XCTAssertEqual(step.snappedObjectIDs, [.init(rawValue: 2)], "zastąpione")
        let merged = BubbleResult(id: .init(rawValue: 2), physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1))
        batch = TransactionStager.stageBatch([pending(WorldTransaction()
            .mergeBubbles([.init(rawValue: 2), .init(rawValue: 3)], result: merged))], against: step.state)
        step = try await stepper.completePublishedStep(batch, duration: 0.001)
        XCTAssertEqual(step.snappedObjectIDs, [.init(rawValue: 2)], "scalone")
        let first = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 2), physicsMaterialID: .init(rawValue: 1),
                                                         renderMaterialID: .init(rawValue: 1)), share: 0.5)
        let second = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 4), physicsMaterialID: .init(rawValue: 1),
                                                          renderMaterialID: .init(rawValue: 1)), share: 0.5)
        batch = TransactionStager.stageBatch([pending(WorldTransaction().splitBubble(.init(rawValue: 2), first: first, second: second))],
                                             against: step.state)
        step = try await stepper.completePublishedStep(batch, duration: 0.001)
        XCTAssertEqual(step.snappedObjectIDs, [.init(rawValue: 2), .init(rawValue: 4)], "podzielone")
    }

    func testWrapRetainsOvershootAcrossSeveralRegionWidths() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .wrap)
        state.objects[.init(rawValue: 1)]?.position = [-25, 5]
        state.objects[.init(rawValue: 1)]?.velocity = [-4, 0]
        let complete = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25)
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
        state = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        let wrapped = try XCTUnwrap(state.objects[.init(rawValue: 1)])
        let dx = max(0, max(-wrapped.position.x, wrapped.position.x - 10))
        let dy = max(0, max(-wrapped.position.y, wrapped.position.y - 10))
        XCTAssertLessThanOrEqual(sqrt(dx * dx + dy * dy), 1)
        state = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        let next = try XCTUnwrap(state.objects[.init(rawValue: 1)])
        XCTAssertEqual(next.position.x, wrapped.position.x, accuracy: 0.0001)
        XCTAssertEqual(next.position.y, wrapped.position.y, accuracy: 0.0001)
        XCTAssertEqual(next.velocity, .zero)
    }

    func testDrivenRigidBodyDescriptorsAreAcceptedWithoutStallingWorld() async throws {
        for role in [MotionRole.pathDriven, .playerDriven] {
            let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
            world.submit(try WorldTransaction()
                .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
                .updatePhysicsMaterial(.init(rawValue: 2), material: PhysicsMaterial(kind: .rigid))
                .add(.rigidBody(RigidBodyDescriptor(id: .init(rawValue: 3), vertices: [[0, 0], [1, 0], [0, 1]],
                    position: [3, 3], motionRole: role, physicsMaterialID: .init(rawValue: 2), renderMaterialID: .init(rawValue: 1)))))
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
            let complete = try await stepper.completePublishedStep(TransactionStager.stageBatch([pending], against: initial(policy: .remove)), duration: 0.25)
            XCTAssertEqual(complete.state.physicsMaterials[.init(rawValue: 1)], material)
        }
    }

    func testUnsupportedMergeResultRoleIsRejectedWithoutRetryingFrame() async throws {
        let world = try await seededWorld()
        let token = world.submit(WorldTransaction().mergeBubbles([.init(rawValue: 1), .init(rawValue: 2)],
            result: BubbleResult(id: .init(rawValue: 3), physicsMaterialID: .init(rawValue: 1),
                renderMaterialID: .init(rawValue: 1), motionRole: .motorDriven)))
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.stepIndex, 2)
        XCTAssertEqual(frame.events, [.transactionRejected(token, TransactionRejection(operationIndex: 0,
            reason: .unsupportedMotionRole(.init(rawValue: 3), .motorDriven)))])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    func testUnsupportedSplitResultRoleIsRejectedWithoutRetryingFrame() async throws {
        let world = try await seededWorld()
        let first = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 3),
            physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)), share: 0.5)
        let second = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 4),
            physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1), motionRole: .pathDriven), share: 0.5)
        let token = world.submit(WorldTransaction().splitBubble(.init(rawValue: 1), first: first, second: second))
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.stepIndex, 2)
        XCTAssertEqual(frame.events, [.transactionRejected(token, TransactionRejection(operationIndex: 0,
            reason: .unsupportedMotionRole(.init(rawValue: 4), .pathDriven)))])
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    func testKinematicMergeAndSplitResultRolesAreRejectedWithoutRetryingFrame() async throws {
        let world = try await seededWorld()
        let merge = world.submit(WorldTransaction().mergeBubbles([.init(rawValue: 1), .init(rawValue: 2)],
            result: BubbleResult(id: .init(rawValue: 3), physicsMaterialID: .init(rawValue: 1),
                renderMaterialID: .init(rawValue: 1), motionRole: .kinematic)))
        var frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.events, [.transactionRejected(merge, TransactionRejection(operationIndex: 0,
            reason: .unsupportedMotionRole(.init(rawValue: 3), .kinematic)))])
        let first = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 3),
            physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1), motionRole: .kinematic), share: 0.5)
        let second = BubbleSplitPart(result: BubbleResult(id: .init(rawValue: 4),
            physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)), share: 0.5)
        let split = world.submit(WorldTransaction().splitBubble(.init(rawValue: 1), first: first, second: second))
        frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.events, [.transactionRejected(split, TransactionRejection(operationIndex: 0,
            reason: .unsupportedMotionRole(.init(rawValue: 3), .kinematic)))])
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
            let complete = try await stepper.completePublishedStep(TransactionStager.stageBatch([
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
        state = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        XCTAssertEqual(try XCTUnwrap(state.objects[.init(rawValue: 1)]).position.x, 10, accuracy: 0.0001)
        // Po drugim kroku x=11, promień=0.975: cały collider opuścił region.
        state = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        XCTAssertNil(state.objects[.init(rawValue: 1)])
        XCTAssertTrue(state.transitions.isEmpty)
        XCTAssertTrue(state.transitionProgress.isEmpty)
    }

    func testWrapPreservesVelocityAndDoesNotCreateSeamContact() async throws {
        let stepper = try NativeCompleteStepper(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var state = try initial(policy: .wrap)
        // Opposite-edge bubble overlaps only a toroidal image, never the real collider.
        let other = try BubbleDescriptor(id: .init(rawValue: 2), position: [0.25, 5], targetRadius: 1,
            physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1))
        state = try TransactionStager.stage(WorldTransaction().add(.bubble(other)), against: state).state
        state = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
        XCTAssertEqual(try XCTUnwrap(state.objects[other.id]).position.x, 0.25, accuracy: 0.0001)
        for _ in 0..<2 {
            state = try await stepper.completePublishedStep(TransactionStager.stageBatch([], against: state), duration: 0.25).state
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
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial()).add(object.descriptor))
        // Limit backlogu (0,25 s) pozwala na jeden krok na wywołanie przy kroku 0,25 s.
        for _ in 0..<3 { _ = await world.advance(by: 0.25) }
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
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: .init(rawValue: 1), position: [9, 5], velocity: [4, 0],
                targetRadius: 1, regionExitPolicy: policy, physicsMaterialID: .init(rawValue: 1),
                renderMaterialID: .init(rawValue: 1)))), against: state).state
    }

    private func seededWorld() async throws -> BubbleWorld {
        let world = try BubbleWorld(configuration: initial(policy: .remove).configuration)
        let transaction = try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: .init(rawValue: 1), position: [3, 3], targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1))))
            .add(.bubble(BubbleDescriptor(id: .init(rawValue: 2), position: [7, 3], targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1))))
        world.submit(transaction)
        let frame = await world.advance(by: 0.25)
        XCTAssertEqual(frame.stepIndex, 1)
        return world
    }
}
