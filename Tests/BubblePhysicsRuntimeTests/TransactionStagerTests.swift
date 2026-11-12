import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

final class TransactionStagerTests: XCTestCase {
    private let materialID = PhysicsMaterialID(rawValue: 1)
    private let styleID = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func state() throws -> RuntimeState {
        RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-100, -100], max: [100, 100])))
    }
    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(styleID, material: try RenderMaterial())
    }
    private func bubble(_ value: UInt64, role: MotionRole = .dynamic,
                        position: WorldPoint = .zero) throws -> BubbleDescriptor {
        try BubbleDescriptor(id: id(value), position: position, targetRadius: 2,
                             mass: 2, motionRole: role, physicsMaterialID: materialID,
                             renderMaterialID: styleID, eventInterest: [.didAdd, .didRemove, .didReplace])
    }

    func testRejectedTransactionPublishesNoPartialObjectOrResourceChange() throws {
        let initial = try state()
        let transaction = try resources().add(.bubble(bubble(1))).remove(id(999))
        XCTAssertThrowsError(try TransactionStager.stage(transaction, against: initial)) { error in
            XCTAssertEqual(error as? TransactionRejection,
                           TransactionRejection(operationIndex: 3, reason: .objectNotFound(self.id(999))))
        }
        XCTAssertTrue(initial.objects.isEmpty)
        XCTAssertTrue(initial.physicsMaterials.isEmpty)
    }

    func testAcceptedTransactionsApplyInSubmissionOrderAtOneFixedStepBoundary() throws {
        let transactions = try [resources().add(.bubble(bubble(1))),
                                WorldTransaction().applyImpulse(to: id(1), impulse: [6, 0]),
                                WorldTransaction().setGlobalForce([0, -5])]
        let tokens: [UInt64] = [30, 10, 20]
        let boundary = TransactionStager.stageBatch(transactions.enumerated().map {
            PendingTransaction(token: TransactionToken(rawValue: tokens[$0.offset]), transaction: $0.element)
        }, against: try state())
        XCTAssertEqual(boundary.state.objects[id(1)]?.velocity, [3, 0])
        XCTAssertEqual(boundary.state.globalForce, [0, -5])
        XCTAssertEqual(boundary.frame.transactionReceipts.map(\.token.rawValue), [30, 10, 20])
    }

    func testInvalidCommandHasStructuredRejectionInNextFrame() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let bad = WorldTransaction().setGlobalForce([7, 8]).applyImpulse(to: id(1), impulse: [.nan, 0])
        let boundary = TransactionStager.stageBatch([
            PendingTransaction(token: TransactionToken(rawValue: 3), transaction: bad),
            PendingTransaction(token: TransactionToken(rawValue: 4), transaction: WorldTransaction().setGlobalForce([1, 2]))
        ], against: initial)
        XCTAssertEqual(boundary.frame.events, [.transactionRejected(
            TransactionToken(rawValue: 3), TransactionRejection(operationIndex: 1,
                reason: .invalidValue(.nonFiniteValue("impulse"))))])
        XCTAssertEqual(boundary.frame.transactionReceipts.map(\.token.rawValue), [4])
        XCTAssertEqual(boundary.state.globalForce, [1, 2])
        XCTAssertEqual(initial.globalForce, .zero)
        XCTAssertEqual(boundary.state.objects[id(1)]?.velocity, .zero)
    }

    // Bez AABB z solvera (bańka jeszcze nie policzona) obwiednia musi objąć kontur o promieniu kolizji,
    // także gdy `effectiveRadius` (minimalny promień konturu) jest od niego mniejszy.
    func testPublishedBubbleBoundsFallbackEnclosesCollisionAndTargetRadius() throws {
        var staged = try TransactionStager.stage(resources().add(.bubble(bubble(1, position: [10, 20]))),
                                                 against: state()).state
        staged.objects[id(1)]?.effectiveRadius = 1
        staged.objects[id(1)]?.collisionRadius = 3
        staged.objects[id(1)]?.targetRadius = 2
        XCTAssertNil(staged.objects[id(1)]?.bounds)
        let published = try XCTUnwrap(staged.publishedObjectStates()[id(1)])
        XCTAssertEqual(published.bounds.min, [7, 17])
        XCTAssertEqual(published.bounds.max, [13, 23])
        staged.objects[id(1)]?.collisionRadius = 1
        let shrunk = try XCTUnwrap(staged.publishedObjectStates()[id(1)])
        XCTAssertEqual(shrunk.bounds.min, [8, 18], "przy mniejszym promieniu kolizji obejmuje promień docelowy")
    }

    func testMissingAndIncompatibleResourcesAreRejected() throws {
        assertRejected(WorldTransaction().add(.bubble(try bubble(1))), reason: .physicsMaterialNotFound(materialID))
        assertRejected(try resources().updatePhysicsMaterial(materialID, material: PhysicsMaterial(kind: .rigid))
            .add(.bubble(bubble(1))), reason: .incompatiblePhysicsMaterial(materialID, id(1)))
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        assertRejected(WorldTransaction().updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .rigid)),
                       against: initial, reason: .incompatiblePhysicsMaterial(materialID, id(1)))
    }

    func testDuplicateIDsAndStaticRegionValidationAreAtomic() throws {
        assertRejected(try resources().add(.bubble(bubble(1))).add(.bubble(bubble(1))), reason: .duplicateObjectID(id(1)))
        assertRejected(try resources().add(.bubble(bubble(1, role: .static, position: [100, 0]))),
                       reason: .invalidValue(.staticGeometryOutsideSimulationRegion))
        assertRejected(try resources().add(.bubble(bubble(1, position: [100, 0]))).setMotion(id(1), role: .static),
                       reason: .invalidValue(.staticGeometryOutsideSimulationRegion))
    }

    func testCompletedRadiusTransitionCannotMakeBubbleStaticOutsideRegion() throws {
        let configuration = try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-10, -10], max: [10, 10]))
        let initial = RuntimeState(configuration: configuration)
        let bubble = try BubbleDescriptor(id: id(1), position: [8, 0], targetRadius: 1,
            physicsMaterialID: materialID, renderMaterialID: styleID)
        let transition = ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(3), duration: 1)
        var state = try TransactionStager.stage(try resources().add(.bubble(bubble))
            .startTransition(transition), against: initial).state
        try MotionControllers.prepare(&state, duration: 1)
        XCTAssertEqual(state.objects[id(1)]?.targetRadius, 3)
        XCTAssertTrue(state.transitions.isEmpty)

        assertRejected(WorldTransaction().setMotion(id(1), role: .static), against: state,
            reason: .invalidValue(.staticGeometryOutsideSimulationRegion))
        XCTAssertEqual(state.objects[id(1)]?.motionRole, .dynamic)
    }

    func testDriveLifecycleAndInvalidRoles() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let driven = try TransactionStager.stage(WorldTransaction()
            .beginPlayerDrive(id(1), target: [2, 3]).updatePlayerDrive(id(1), target: [4, 5]), against: initial).state
        XCTAssertEqual(driven.objects[id(1)]?.motionRole, .playerDriven)
        XCTAssertEqual(driven.objects[id(1)]?.playerDriveTarget, [4, 5])
        let ended = try TransactionStager.stage(WorldTransaction().endPlayerDrive(id(1)), against: driven).state
        XCTAssertEqual(ended.objects[id(1)]?.motionRole, .dynamic)
        XCTAssertNil(ended.objects[id(1)]?.playerDriveTarget)
        assertRejected(WorldTransaction().updatePlayerDrive(id(1), target: .zero), against: initial, reason: .driveNotActive(id(1)))
        assertRejected(WorldTransaction().applyImpulse(to: id(1), impulse: [1, 0]), against: driven, reason: .incompatibleMotionRole(id(1)))
    }

    func testTransitionReplacementAndInvalidTargetAreAtomic() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let first = ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(4), duration: 2)
        let second = ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(7), duration: 3)
        let changed = try TransactionStager.stage(WorldTransaction().startTransition(first).startTransition(second), against: initial)
        XCTAssertEqual(changed.state.transitions[.bubbleRadius(id(1))], second)
        assertRejected(WorldTransaction().startTransition(first).startTransition(
            ParameterTransition(target: .globalForce, value: .scalar(3), duration: 1)), against: initial,
                       reason: .incompatibleTransitionValue)
        XCTAssertTrue(initial.transitions.isEmpty)
    }

    func testMergeAndSplitReserveStableResultIDsAndRejectPartialResults() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))).add(.bubble(bubble(2))), against: state()).state
        let result = BubbleResult(id: id(3), physicsMaterialID: materialID, renderMaterialID: styleID)
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)], result: result), against: initial)
        XCTAssertEqual(Set(merged.state.objects.keys), [id(3)])
        XCTAssertEqual(merged.createdObjectIDs, [id(3)])
        let split = WorldTransaction().splitBubble(id(3), first: BubbleSplitPart(result:
            BubbleResult(id: id(4), physicsMaterialID: materialID, renderMaterialID: styleID), share: 0.25),
            second: BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: materialID, renderMaterialID: styleID), share: 0.75))
        let separated = try TransactionStager.stage(split, against: merged.state)
        XCTAssertEqual(Set(separated.state.objects.keys), [id(4), id(5)])
        assertRejected(WorldTransaction().mergeBubbles([id(1), id(1)], result: result), against: initial,
                       reason: .invalidStructuralOperation)
        assertRejected(WorldTransaction().mergeBubbles([id(1), id(2)], result: result).remove(id(999)), against: initial,
                       reason: .objectNotFound(id(999)))
        XCTAssertEqual(Set(initial.objects.keys), [id(1), id(2)])
    }

    func testReplaceRemoveAndPolygonReplacementValidateProspectiveObjects() throws {
        let polygonMaterial = PhysicsMaterialID(rawValue: 2)
        func polygon(_ value: UInt64) throws -> RigidBodyDescriptor {
            try RigidBodyDescriptor(id: id(value), vertices: [[0, 0], [1, 0], [0, 1]],
                                  physicsMaterialID: polygonMaterial, renderMaterialID: styleID)
        }
        let transaction = try resources()
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .rigid))
            .add(.bubble(bubble(1))).replace(id(1), with: .rigidBody(polygon(1)))
            .replaceRigidBodies([id(1)], with: [polygon(2), polygon(3)]).remove(id(2))
        let changed = try TransactionStager.stage(transaction, against: state())
        XCTAssertEqual(Set(changed.state.objects.keys), [id(3)])
        assertRejected(try resources().add(.bubble(bubble(1))).replaceRigidBodies([id(1)], with: [polygon(2)]),
                       reason: .incompatibleObjectKind(id(1)))
    }

    func testCommandsRejectInvalidNumbersAndUnsupportedObjectKinds() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        assertRejected(WorldTransaction().setGlobalForce([.infinity, 0]), against: initial,
                       reason: .invalidValue(.nonFiniteValue("globalForce")))
        assertRejected(WorldTransaction().beginPlayerDrive(id(1), target: [0, .nan]), against: initial,
                       reason: .invalidValue(.nonFiniteValue("playerDrive.target")))
        assertRejected(WorldTransaction().beginPlayerDrive(id(1), target: .zero).beginPlayerDrive(id(1), target: .zero),
                       against: initial, reason: .driveAlreadyActive(id(1)))
        assertRejected(WorldTransaction().endPlayerDrive(id(1)), against: initial, reason: .driveNotActive(id(1)))
        assertRejected(WorldTransaction().setMotion(id(1), role: .playerDriven), against: initial, reason: .driveNotActive(id(1)))
        assertRejected(WorldTransaction().replace(id(1), with: .bubble(try bubble(2))), against: initial,
                       reason: .replacementIDMismatch(id(1), id(2)))
        let sensor = try SensorDescriptor(id: id(2), position: .zero, geometry: .circle(radius: 1))
        let field = try ForceFieldDescriptor(id: id(3), position: .zero, geometry: .circle(radius: 1),
                                            field: .directional(force: [1, 0]))
        let ranges = try TransactionStager.stage(WorldTransaction().add(.sensor(sensor)).add(.forceField(field)), against: initial).state
        assertRejected(WorldTransaction().applyImpulse(to: id(2), impulse: [1, 0]), against: ranges, reason: .incompatibleObjectKind(id(2)))
        assertRejected(WorldTransaction().beginPlayerDrive(id(3), target: [1, 0]), against: ranges, reason: .incompatibleObjectKind(id(3)))
        assertRejected(WorldTransaction().setMotion(id(2), role: .dynamic), against: ranges, reason: .incompatibleObjectKind(id(2)))
    }

    func testInvalidSecondSplitResultRollsBackRemovalAndFirstResult() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let good = BubbleResult(id: id(2), physicsMaterialID: materialID, renderMaterialID: styleID)
        let bad = BubbleResult(id: id(3), physicsMaterialID: PhysicsMaterialID(rawValue: 999), renderMaterialID: styleID)
        assertRejected(WorldTransaction().splitBubble(id(1), first: BubbleSplitPart(result: good, share: 0.5),
            second: BubbleSplitPart(result: bad, share: 0.5)), against: initial,
                       reason: .physicsMaterialNotFound(PhysicsMaterialID(rawValue: 999)))
        for share: Float in [0, -1, .nan, .infinity, 0.6] {
            assertRejected(WorldTransaction().splitBubble(id(1), first: BubbleSplitPart(result: good, share: share),
                second: BubbleSplitPart(result: bad, share: 0.5)), against: initial, reason: .invalidStructuralOperation)
        }
        XCTAssertEqual(Set(initial.objects.keys), [id(1)])
    }

    func testTransitionTargetsValidateValuesAndRemovedObjectsLoseSchedules() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let transitions = [
            ParameterTransition(target: .globalForce, value: .vector([0, -3]), duration: 0),
            ParameterTransition(target: .physicsMaterial(materialID, .friction), value: .scalar(2), duration: 1),
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(3), duration: 1)
        ]
        let scheduled = try TransactionStager.stage(transitions.reduce(WorldTransaction()) { $0.startTransition($1) }, against: initial).state
        XCTAssertEqual(scheduled.transitions.count, 3)
        let removed = try TransactionStager.stage(WorldTransaction().remove(id(1)), against: scheduled).state
        XCTAssertEqual(removed.transitions.count, 2)
        XCTAssertNil(removed.transitions[.bubbleRadius(id(1))])
        assertRejected(WorldTransaction().startTransition(ParameterTransition(target: .globalForce, value: .vector(.zero), duration: .nan)),
                       against: initial, reason: .invalidValue(.nonFiniteValue("transition.duration")))
        assertRejected(WorldTransaction().startTransition(ParameterTransition(target: .globalForce, value: .vector(.zero), duration: -1)),
                       against: initial, reason: .invalidValue(.valueOutOfRange("transition.duration")))
        assertRejected(WorldTransaction().startTransition(ParameterTransition(target: .physicsMaterial(materialID, .restitution), value: .scalar(2), duration: 1)),
                       against: initial, reason: .invalidValue(.valueOutOfRange("transition.material")))
        assertRejected(WorldTransaction().startTransition(ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(0), duration: 1)),
                       against: initial, reason: .invalidValue(.nonPositiveValue("transition.radius")))
        assertRejected(WorldTransaction().startTransition(ParameterTransition(target: .globalForce, value: .vector(.zero), duration: 1,
            curve: .cubicBezier(x1: 1, y1: 0, x2: 0, y2: 1))), against: initial,
                       reason: .invalidValue(.valueOutOfRange("transition.curve")))
    }

    func testRejectedBatchDoesNotLeakEventsReceiptsOrSharedResourceUpdates() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let transaction = try WorldTransaction().remove(id(1)).add(.bubble(bubble(2)))
            .updateRenderMaterial(styleID, material: RenderMaterial())
            .updatePhysicsMaterial(materialID, material: PhysicsMaterial(kind: .bubble, friction: 2))
            .remove(id(999))
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 1), transaction: transaction)], against: initial)
        XCTAssertEqual(batch.state, initial)
        XCTAssertTrue(batch.changes.isEmpty)
        XCTAssertTrue(batch.frame.transactionReceipts.isEmpty)
        XCTAssertEqual(batch.frame.events.count, 1)
        guard case .transactionRejected = batch.frame.events.first else { return XCTFail("Missing structured rejection") }
    }

    func testStaticMotionChangeValidatesAlreadyScheduledRadiusTransition() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let growing = WorldTransaction().startTransition(ParameterTransition(
            target: .bubbleRadius(id(1)), value: .scalar(200), duration: 1))
        assertRejected(growing.setMotion(id(1), role: .static), against: initial,
                       reason: .invalidValue(.staticGeometryOutsideSimulationRegion))
    }

    func testInvalidPolygonRollsBackValidObjectAndResourceChanges() throws {
        let initial = try state()
        let polygonMaterial = PhysicsMaterialID(rawValue: 2)
        let outside = try RigidBodyDescriptor(id: id(2), vertices: [[0, 0], [2, 0], [0, 2]], position: [100, 100],
                                            physicsMaterialID: polygonMaterial, renderMaterialID: styleID)
        let transaction = try resources().add(.bubble(bubble(1)))
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .rigid)).add(.rigidBody(outside))
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 1), transaction: transaction)], against: initial)
        XCTAssertEqual(batch.state, initial)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 1),
            TransactionRejection(operationIndex: 4, reason: .invalidValue(.staticGeometryOutsideSimulationRegion)))])
        XCTAssertTrue(batch.frame.transactionReceipts.isEmpty)
    }

    func testCircleAndCapsuleAreStagedAndPublishedWithKindAndBounds() throws {
        let rigid = PhysicsMaterialID(rawValue: 2)
        let circle = try RigidBodyDescriptor(id: id(1), shape: .circle(radius: 2), position: [10, 20],
            motionRole: .dynamic, physicsMaterialID: rigid, renderMaterialID: styleID)
        let capsule = try RigidBodyDescriptor(id: id(2), shape: .capsule(halfLength: 3, radius: 1), position: [-10, 5],
            rotation: .pi / 2, motionRole: .dynamic, physicsMaterialID: rigid, renderMaterialID: styleID)
        let staged = try TransactionStager.stage(resources()
            .updatePhysicsMaterial(rigid, material: PhysicsMaterial(kind: .rigid))
            .add(.rigidBody(circle)).add(.rigidBody(capsule)), against: state()).state
        let published = staged.publishedObjectStates()
        XCTAssertEqual(published[id(1)]?.kind, .circle(radius: 2))
        XCTAssertEqual(published[id(1)]?.bounds.min, [8, 18])
        XCTAssertEqual(published[id(1)]?.bounds.max, [12, 22])
        XCTAssertEqual(published[id(2)]?.kind, .capsule(halfLength: 3, radius: 1))
        // Oś obrócona o 90°: wysokość 2·(3 + 1), szerokość 2·1.
        let bounds = try XCTUnwrap(published[id(2)]?.bounds)
        XCTAssertEqual(bounds.min.x, -11, accuracy: 1e-5); XCTAssertEqual(bounds.max.x, -9, accuracy: 1e-5)
        XCTAssertEqual(bounds.min.y, 1, accuracy: 1e-5); XCTAssertEqual(bounds.max.y, 9, accuracy: 1e-5)
        // Bryły kołowe wymagają materiału `.rigid`, jak wielokąty.
        assertRejected(try resources().add(.rigidBody(circle)), reason: .physicsMaterialNotFound(rigid))
        assertRejected(try resources().updatePhysicsMaterial(rigid, material: PhysicsMaterial(kind: .bubble)).add(.rigidBody(circle)),
                       reason: .incompatiblePhysicsMaterial(rigid, id(1)))
    }

    func testStaticCircleOutsideRegionIsRejectedAtStaging() throws {
        let rigid = PhysicsMaterialID(rawValue: 2)
        let outside = try RigidBodyDescriptor(id: id(1), shape: .circle(radius: 5), position: [98, 0],
            motionRole: .static, physicsMaterialID: rigid, renderMaterialID: styleID)
        assertRejected(try resources().updatePhysicsMaterial(rigid, material: PhysicsMaterial(kind: .rigid)).add(.rigidBody(outside)),
                       reason: .invalidValue(.staticGeometryOutsideSimulationRegion))
    }

    func testMergeResultTakesDrivePolicyFromBubbleResultAndDefaultsToStandard() throws {
        let policy = try BubbleDrivePolicy(maximumSpeed: 3)
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))).add(.bubble(bubble(2))), against: state()).state
        let custom = try mergedBubble(against: initial,
            result: BubbleResult(id: id(3), physicsMaterialID: materialID, renderMaterialID: styleID, drivePolicy: policy))
        XCTAssertEqual(custom.drivePolicy, policy)
        let standard = try mergedBubble(against: initial,
            result: BubbleResult(id: id(3), physicsMaterialID: materialID, renderMaterialID: styleID))
        XCTAssertEqual(standard.drivePolicy, .standard)
    }

    func testSplitPartsTakeDrivePolicyFromTheirBubbleResults() throws {
        let policy = try BubbleDrivePolicy(rigidifies: false, maximumSpeed: 3)
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let split = try TransactionStager.stage(WorldTransaction().splitBubble(id(1),
            first: BubbleSplitPart(result: BubbleResult(id: id(4), physicsMaterialID: materialID,
                                                        renderMaterialID: styleID, drivePolicy: policy), share: 0.5),
            second: BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: materialID,
                                                         renderMaterialID: styleID), share: 0.5)), against: initial).state
        guard case .bubble(let first) = try XCTUnwrap(split.objects[id(4)]).descriptor,
              case .bubble(let second) = try XCTUnwrap(split.objects[id(5)]).descriptor else { return XCTFail("brak baniek") }
        XCTAssertEqual(first.drivePolicy, policy)
        XCTAssertEqual(second.drivePolicy, .standard)
    }

    func testMergeMassOverridesResultMassAndNilKeepsTheSumOfSourceMasses() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))).add(.bubble(bubble(2))), against: state()).state
        let overridden = try mergedBubble(against: initial,
            result: BubbleResult(id: id(3), physicsMaterialID: materialID, renderMaterialID: styleID, mass: 10))
        XCTAssertEqual(overridden.mass, 10)
        let summed = try mergedBubble(against: initial,
            result: BubbleResult(id: id(3), physicsMaterialID: materialID, renderMaterialID: styleID))
        XCTAssertEqual(summed.mass, 4)
        assertRejected(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: BubbleResult(id: id(3), physicsMaterialID: materialID, renderMaterialID: styleID, mass: 0)),
            against: initial, reason: .invalidValue(.nonPositiveValue("bubble.mass")))
    }

    func testMergeVelocityIsSourceMomentumOverSourceMassRegardlessOfOverriddenMass() throws {
        let light = try BubbleDescriptor(id: id(1), position: [0, 0], velocity: [4, 0], targetRadius: 1, mass: 1,
                                         physicsMaterialID: materialID, renderMaterialID: styleID)
        let heavy = try BubbleDescriptor(id: id(2), position: [1, 0], velocity: [0, 0], targetRadius: 1, mass: 3,
                                         physicsMaterialID: materialID, renderMaterialID: styleID)
        let initial = try TransactionStager.stage(resources().add(.bubble(light)).add(.bubble(heavy)), against: state()).state
        let merged = try mergedBubble(against: initial,
            result: BubbleResult(id: id(3), physicsMaterialID: materialID, renderMaterialID: styleID, mass: 10))
        XCTAssertEqual(merged.velocity.x, 1, accuracy: 1e-6)
        XCTAssertEqual(merged.velocity.y, 0, accuracy: 1e-6)
        XCTAssertEqual(merged.mass, 10)
    }

    func testSplitWithMassInAnyPartIsRejected() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let plain = BubbleResult(id: id(4), physicsMaterialID: materialID, renderMaterialID: styleID)
        let heavy = BubbleResult(id: id(5), physicsMaterialID: materialID, renderMaterialID: styleID, mass: 1)
        assertRejected(WorldTransaction().splitBubble(id(1), first: BubbleSplitPart(result: plain, share: 0.5),
            second: BubbleSplitPart(result: heavy, share: 0.5)), against: initial, reason: .invalidStructuralOperation)
        let heavyFirst = BubbleResult(id: id(4), physicsMaterialID: materialID, renderMaterialID: styleID, mass: 1)
        let plainSecond = BubbleResult(id: id(5), physicsMaterialID: materialID, renderMaterialID: styleID)
        assertRejected(WorldTransaction().splitBubble(id(1), first: BubbleSplitPart(result: heavyFirst, share: 0.5),
            second: BubbleSplitPart(result: plainSecond, share: 0.5)), against: initial, reason: .invalidStructuralOperation)
    }

    private func mergedBubble(against initial: RuntimeState, result: BubbleResult) throws -> BubbleDescriptor {
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)], result: result),
                                                 against: initial).state
        guard case .bubble(let descriptor) = try XCTUnwrap(merged.objects[result.id]).descriptor else {
            XCTFail("wynik scalenia nie jest bańką"); throw TransactionRejectionReason.incompatibleObjectKind(result.id)
        }
        return descriptor
    }

    private func assertRejected(_ transaction: WorldTransaction, against initial: RuntimeState? = nil,
                                reason: TransactionRejectionReason, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let original = try initial ?? state()
            XCTAssertThrowsError(try TransactionStager.stage(transaction, against: original), file: file, line: line) { error in
                XCTAssertEqual((error as? TransactionRejection)?.reason, reason, file: file, line: line)
            }
        } catch { XCTFail("Unexpected fixture failure: \(error)", file: file, line: line) }
    }
}
