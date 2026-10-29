import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

final class TransactionStagerTests: XCTestCase {
    private let materialID = PhysicsMaterialID(rawValue: 1)
    private let styleID = RenderStyleID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func state() throws -> RuntimeState {
        RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-100, -100], max: [100, 100])))
    }
    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble))
            .updateRenderStyle(styleID, style: try RenderStyle())
    }
    private func bubble(_ value: UInt64, role: MotionRole = .dynamic,
                        position: WorldPoint = .zero,
                        drivePolicy: BubbleDrivePolicy = .standard) throws -> BubbleDescriptor {
        try BubbleDescriptor(id: id(value), position: position, targetRadius: 2,
                             mass: 2, motionRole: role, physicsMaterialID: materialID,
                             renderStyleID: styleID, eventInterest: [.didAdd, .didRemove, .didReplace], drivePolicy: drivePolicy)
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
        XCTAssertTrue(initial.renderStyles.isEmpty)
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

    func testMissingAndIncompatibleResourcesAreRejected() throws {
        assertRejected(WorldTransaction().add(.bubble(try bubble(1))), reason: .physicsMaterialNotFound(materialID))
        assertRejected(try resources().updatePhysicsMaterial(materialID, material: PhysicsMaterial(kind: .polygon))
            .add(.bubble(bubble(1))), reason: .incompatiblePhysicsMaterial(materialID, id(1)))
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        assertRejected(WorldTransaction().updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .polygon)),
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
            physicsMaterialID: materialID, renderStyleID: styleID)
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
        let drive = try BubbleDrivePolicy(maximumSpeed: 30, distanceResponse: 12)
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1, drivePolicy: drive))).add(.bubble(bubble(2, drivePolicy: drive))), against: state()).state
        let result = BubbleResult(id: id(3), physicsMaterialID: materialID, renderStyleID: styleID)
        let merged = try TransactionStager.stage(WorldTransaction().mergeBubbles([id(1), id(2)], result: result), against: initial)
        XCTAssertEqual(Set(merged.state.objects.keys), [id(3)])
        XCTAssertEqual(merged.createdObjectIDs, [id(3)])
        guard case .bubble(let mergedBubble) = merged.state.objects[id(3)]?.descriptor else {
            return XCTFail("Expected merged bubble")
        }
        XCTAssertEqual(mergedBubble.drivePolicy, drive)
        let split = WorldTransaction().splitBubble(id(3), first: BubbleSplitPart(result:
            BubbleResult(id: id(4), physicsMaterialID: materialID, renderStyleID: styleID), share: 0.25),
            second: BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: materialID, renderStyleID: styleID), share: 0.75))
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
        func polygon(_ value: UInt64) throws -> PolygonDescriptor {
            try PolygonDescriptor(id: id(value), vertices: [[0, 0], [1, 0], [0, 1]],
                                  physicsMaterialID: polygonMaterial, renderStyleID: styleID)
        }
        let transaction = try resources()
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .polygon))
            .add(.bubble(bubble(1))).replace(id(1), with: .polygon(polygon(1)))
            .replacePolygons([id(1)], with: [polygon(2), polygon(3)]).remove(id(2))
        let changed = try TransactionStager.stage(transaction, against: state())
        XCTAssertEqual(Set(changed.state.objects.keys), [id(3)])
        assertRejected(try resources().add(.bubble(bubble(1))).replacePolygons([id(1)], with: [polygon(2)]),
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
        let sensor = try SensorDescriptor(id: id(2), position: .zero, geometry: .circle(radius: 1), renderStyleID: styleID)
        let field = try ForceFieldDescriptor(id: id(3), position: .zero, geometry: .circle(radius: 1),
                                            field: .directional(force: [1, 0]), renderStyleID: styleID)
        let ranges = try TransactionStager.stage(WorldTransaction().add(.sensor(sensor)).add(.forceField(field)), against: initial).state
        assertRejected(WorldTransaction().applyImpulse(to: id(2), impulse: [1, 0]), against: ranges, reason: .incompatibleObjectKind(id(2)))
        assertRejected(WorldTransaction().beginPlayerDrive(id(3), target: [1, 0]), against: ranges, reason: .incompatibleObjectKind(id(3)))
        assertRejected(WorldTransaction().setMotion(id(2), role: .dynamic), against: ranges, reason: .incompatibleObjectKind(id(2)))
    }

    func testInvalidSecondSplitResultRollsBackRemovalAndFirstResult() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let good = BubbleResult(id: id(2), physicsMaterialID: materialID, renderStyleID: styleID)
        let bad = BubbleResult(id: id(3), physicsMaterialID: materialID, renderStyleID: RenderStyleID(rawValue: 999))
        assertRejected(WorldTransaction().splitBubble(id(1), first: BubbleSplitPart(result: good, share: 0.5),
            second: BubbleSplitPart(result: bad, share: 0.5)), against: initial,
                       reason: .renderStyleNotFound(RenderStyleID(rawValue: 999)))
        for share: Float in [0, -1, .nan, .infinity, 0.6] {
            assertRejected(WorldTransaction().splitBubble(id(1), first: BubbleSplitPart(result: good, share: share),
                second: BubbleSplitPart(result: bad, share: 0.5)), against: initial, reason: .invalidStructuralOperation)
        }
        XCTAssertEqual(Set(initial.objects.keys), [id(1)])
    }

    func testTransitionTargetsValidateValuesAndRemovedObjectsLoseSchedules() throws {
        let initial = try TransactionStager.stage(resources().add(.bubble(bubble(1))), against: state()).state
        let parameter = ParameterID(rawValue: "highlight")
        let transitions = [
            ParameterTransition(target: .globalForce, value: .vector([0, -3]), duration: 0),
            ParameterTransition(target: .physicsMaterial(materialID, .friction), value: .scalar(2), duration: 1),
            ParameterTransition(target: .renderStyle(styleID, parameter), value: .scalar(1), duration: 1),
            ParameterTransition(target: .objectPresentation(id(1), parameter), value: .scalar(1), duration: 1),
            ParameterTransition(target: .bubbleRadius(id(1)), value: .scalar(3), duration: 1)
        ]
        let scheduled = try TransactionStager.stage(transitions.reduce(WorldTransaction()) { $0.startTransition($1) }, against: initial).state
        XCTAssertEqual(scheduled.transitions.count, 5)
        let removed = try TransactionStager.stage(WorldTransaction().remove(id(1)), against: scheduled).state
        XCTAssertEqual(removed.transitions.count, 3)
        XCTAssertNil(removed.transitions[.bubbleRadius(id(1))])
        XCTAssertNil(removed.transitions[.objectPresentation(id(1), parameter)])
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
            .updateRenderStyle(styleID, style: RenderStyle(channels: [ParameterID(rawValue: "test"): 1]))
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
        let outside = try PolygonDescriptor(id: id(2), vertices: [[0, 0], [2, 0], [0, 2]], position: [100, 100],
                                            physicsMaterialID: polygonMaterial, renderStyleID: styleID)
        let transaction = try resources().add(.bubble(bubble(1)))
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .polygon)).add(.polygon(outside))
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 1), transaction: transaction)], against: initial)
        XCTAssertEqual(batch.state, initial)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 1),
            TransactionRejection(operationIndex: 4, reason: .invalidValue(.staticGeometryOutsideSimulationRegion)))])
        XCTAssertTrue(batch.frame.transactionReceipts.isEmpty)
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
