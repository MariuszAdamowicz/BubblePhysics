import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-26 i P-B-70 (G11-AC3): walidacja więzów w stagerze, role ciał, usuwanie więzów razem z ciałami.
final class JointStagingTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let styleID = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func joint(_ value: UInt64) -> JointID { JointID(rawValue: value) }

    private func emptyState() throws -> RuntimeState {
        RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-100, -100], max: [100, 100])))
    }

    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(rigidMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(styleID, material: try RenderMaterial())
    }

    private func bubble(_ value: UInt64, role: MotionRole = .dynamic, at x: Float = 0) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: [x, 0], targetRadius: 2, mass: 2, motionRole: role,
                                     physicsMaterialID: bubbleMaterial, renderMaterialID: styleID))
    }

    private func box(_ value: UInt64, role: MotionRole = .dynamic, at x: Float = 0) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), vertices: [[-1, -1], [1, -1], [1, 1], [-1, 1]],
            position: [x, 0], motionRole: role, physicsMaterialID: rigidMaterial, renderMaterialID: styleID))
    }

    private func circle(_ value: UInt64, role: MotionRole = .dynamic, at x: Float = 0) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), shape: .circle(radius: 1), position: [x, 0], motionRole: role,
                                           physicsMaterialID: rigidMaterial, renderMaterialID: styleID))
    }

    // Fabryki więzów nie rzucają (stałe, poprawne argumenty); testy sprawdzają staging, nie konstruktor.
    private func distance(_ value: UInt64, _ a: UInt64, _ b: UInt64?) -> Joint {
        try! Joint(id: joint(value), bodyA: id(a), bodyB: b.map(id), anchorB: [0, 5],
                  kind: .distance(length: 5, softness: 0, damping: 0))
    }

    private func hinge(_ value: UInt64, _ a: UInt64, _ b: UInt64?) -> Joint {
        try! Joint(id: joint(value), bodyA: id(a), bodyB: b.map(id), kind: .hinge(limits: nil, motor: nil))
    }

    private func weld(_ value: UInt64, _ a: UInt64, _ b: UInt64?) -> Joint {
        try! Joint(id: joint(value), bodyA: id(a), bodyB: b.map(id), kind: .weld)
    }

    /// Świat z ciałami o podanych rolach; ciała dodane bez więzów.
    private func world(_ objects: [WorldObject]) throws -> RuntimeState {
        var transaction = try resources()
        for object in objects { transaction = transaction.add(object) }
        return try TransactionStager.stage(transaction, against: emptyState()).state
    }

    private func assertRejected(_ transaction: WorldTransaction, against state: RuntimeState, index: Int? = nil,
                                reason: TransactionRejectionReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try TransactionStager.stage(transaction, against: state), file: file, line: line) { error in
            let rejection = error as? TransactionRejection
            XCTAssertEqual(rejection?.reason, reason, file: file, line: line)
            if let index { XCTAssertEqual(rejection?.operationIndex, index, file: file, line: line) }
        }
    }

    private func assertAccepted(_ transaction: WorldTransaction, against state: RuntimeState,
                                file: StaticString = #filePath, line: UInt = #line) throws -> StagedWorldChange {
        do { return try TransactionStager.stage(transaction, against: state) }
        catch { XCTFail("odrzucone: \(error)", file: file, line: line); throw error }
    }

    // MARK: P-B-26: bańka tylko w więzie dystansowym

    func testHingeAndWeldWithBubbleAreRejectedExplicitlyButDistanceIsAccepted() throws {
        let state = try world([bubble(1), box(2), bubble(3, at: 10)])
        assertRejected(WorldTransaction().addJoint(hinge(1, 1, 2)), against: state, index: 0, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().addJoint(hinge(1, 2, 1)), against: state, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().addJoint(weld(4, 1, 2)), against: state, reason: .unsupportedJointBody(joint(4)))
        assertRejected(WorldTransaction().addJoint(weld(5, 1, nil)), against: state, reason: .unsupportedJointBody(joint(5)))
        assertRejected(WorldTransaction().addJoint(hinge(6, 1, 3)), against: state, reason: .unsupportedJointBody(joint(6)))
        // Dystans: bańka–bryła, bańka–świat, bańka–bańka.
        let accepted = try assertAccepted(WorldTransaction().addJoint(distance(1, 1, 2)).addJoint(distance(2, 1, nil))
            .addJoint(distance(3, 1, 3)), against: state)
        XCTAssertEqual(Set(accepted.state.joints.keys), [joint(1), joint(2), joint(3)])
        XCTAssertEqual(accepted.state.joints[joint(3)]?.bodyB, id(3))
    }

    func testRejectedJointTransactionLeavesStateUnchangedInsideBatch() throws {
        let state = try world([bubble(1), box(2)])
        let bad = WorldTransaction().addJoint(distance(1, 1, 2)).addJoint(hinge(2, 1, 2))
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 7), transaction: bad)],
                                                 against: state)
        XCTAssertEqual(batch.state, state)
        XCTAssertTrue(batch.state.joints.isEmpty)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 7),
            TransactionRejection(operationIndex: 1, reason: .unsupportedJointBody(joint(2))))])
    }

    /// Skończona, ale ogromna kotwica, kąt odniesienia albo parametr dystansu (np. 3e38) przepełniała `Float` dopiero
    /// w kroku solvera i zatrzymywała świat; jak napęd kinematyczny ma być odrzucona przy wejściu transakcji.
    func testHugeFiniteJointValuesAreRejectedAtStaging() throws {
        let state = try world([box(1), box(2, at: 5)])
        let huge: Float = 3e38
        let cases: [(Joint, String)] = [
            (try Joint(id: joint(1), bodyA: id(1), bodyB: id(2), anchorA: [huge, 0], kind: .weld), "joint.anchorA"),
            (try Joint(id: joint(1), bodyA: id(1), bodyB: nil, anchorB: [0, -huge], kind: .weld), "joint.anchorB"),
            (try Joint(id: joint(1), bodyA: id(1), bodyB: id(2), referenceAngle: huge, kind: .weld), "joint.referenceAngle"),
            (try Joint(id: joint(1), bodyA: id(1), bodyB: id(2), kind: .distance(length: huge, softness: 0, damping: 0)),
             "joint.length"),
            (try Joint(id: joint(1), bodyA: id(1), bodyB: id(2), kind: .distance(length: 5, softness: huge, damping: 0)),
             "joint.softness"),
            (try Joint(id: joint(1), bodyA: id(1), bodyB: id(2), kind: .distance(length: 5, softness: 0, damping: huge)),
             "joint.damping"),
        ]
        for (candidate, name) in cases {
            assertRejected(WorldTransaction().addJoint(candidate), against: state, index: 0,
                           reason: .invalidValue(.valueOutOfRange(name)))
        }
        // Granica 1e6 jest jeszcze dopuszczalna.
        _ = try assertAccepted(WorldTransaction().addJoint(try Joint(id: joint(1), bodyA: id(1), bodyB: id(2),
            anchorA: [1e6, -1e6], kind: .distance(length: 1e6, softness: 1e6, damping: 1e6))), against: state)
    }

    // MARK: P-B-70: role ciał

    func testJointBetweenTwoImmobileBodiesOrWithPathDrivenBodyIsRejected() throws {
        let state = try world([box(1, role: .static), box(2, role: .kinematic), box(3, role: .static, at: 5),
                               box(4, role: .kinematic, at: 9), box(5, role: .dynamic, at: 12), circle(6, role: .pathDriven, at: 20)])
        for candidate in [hinge(1, 1, 2), weld(1, 1, 2), distance(1, 1, 2)] {
            assertRejected(WorldTransaction().addJoint(candidate), against: state, index: 0,
                           reason: .unsupportedJointBody(joint(1)))
        }
        assertRejected(WorldTransaction().addJoint(weld(1, 1, 3)), against: state, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().addJoint(weld(1, 2, 4)), against: state, reason: .unsupportedJointBody(joint(1)))
        // Ciało nieruchome ze światem też nie ma ruchomego końca.
        assertRejected(WorldTransaction().addJoint(weld(1, 1, nil)), against: state, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().addJoint(weld(1, 2, nil)), against: state, reason: .unsupportedJointBody(joint(1)))
        // pathDriven: jako jedyny koniec i obok ruchomego.
        assertRejected(WorldTransaction().addJoint(weld(1, 6, nil)), against: state, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().addJoint(weld(1, 6, 5)), against: state, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().addJoint(weld(1, 5, 6)), against: state, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().addJoint(weld(1, 6, 1)), against: state, reason: .unsupportedJointBody(joint(1)))
    }

    func testJointWithMovableBodyIsAcceptedIncludingOneImmobileEndAndWorld() throws {
        var transaction = WorldTransaction().beginPlayerDrive(id(5), target: [1, 1])
        let state = try world([box(1, role: .static), box(2, role: .kinematic), box(3, role: .dynamic, at: 5),
                               box(4, role: .motorDriven, at: 9), circle(5, role: .dynamic, at: 12)])
        transaction = transaction
            .addJoint(weld(1, 1, 3)).addJoint(weld(2, 2, 3)).addJoint(hinge(3, 4, 1)).addJoint(hinge(4, 4, nil))
            .addJoint(weld(5, 3, nil)).addJoint(hinge(6, 5, 2))
        let change = try assertAccepted(transaction, against: state)
        XCTAssertEqual(Set(change.state.joints.keys), Set((1...6).map { joint($0) }))
        XCTAssertEqual(change.state.objects[id(5)]?.motionRole, .playerDriven)
    }

    func testSetMotionThatWouldLeaveJointWithoutMovableBodyIsRejected() throws {
        let base = try world([box(1, role: .static), box(2, role: .dynamic, at: 5), box(3, role: .dynamic, at: 9)])
        let joined = try TransactionStager.stage(WorldTransaction().addJoint(weld(1, 1, 2)).addJoint(hinge(2, 3, nil)),
                                                 against: base).state
        assertRejected(WorldTransaction().setMotion(id(2), role: .kinematic), against: joined, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().setMotion(id(2), role: .static), against: joined, reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().setMotion(id(2), role: .pathDriven), against: joined, reason: .unsupportedJointBody(joint(1)))
        assertRejected(try WorldTransaction().setPathDrive(id(2), drive: PathDrive(points: [[1, 1]], speed: 1)), against: joined,
                       reason: .unsupportedJointBody(joint(1)))
        assertRejected(WorldTransaction().setMotion(id(3), role: .static), against: joined, reason: .unsupportedJointBody(joint(2)))
        // Zmiana między rolami ruchomymi, w tym sterowanie gracza, jest dozwolona.
        let accepted = try assertAccepted(WorldTransaction().setMotion(id(2), role: .motorDriven)
            .beginPlayerDrive(id(3), target: [2, 2]), against: joined)
        XCTAssertEqual(accepted.state.joints.count, 2)
        // Drugi koniec staje się ruchomy, więc pierwszy może zostać nieruchomy.
        let swapped = try assertAccepted(WorldTransaction().setMotion(id(1), role: .kinematic), against: joined)
        XCTAssertEqual(swapped.state.objects[id(1)]?.motionRole, .kinematic)
    }

    func testReplacingBodyWithKindThatJointCannotUseIsRejectedAndOtherwiseKeepsJoint() throws {
        let base = try world([box(1, role: .dynamic), box(2, role: .static, at: 5)])
        let joined = try TransactionStager.stage(WorldTransaction().addJoint(hinge(1, 1, 2)), against: base).state
        assertRejected(try WorldTransaction().replace(id(1), with: bubble(1)), against: joined, reason: .unsupportedJointBody(joint(1)))
        assertRejected(try WorldTransaction().replace(id(1), with: box(1, role: .static)), against: joined, reason: .unsupportedJointBody(joint(1)))
        let kept = try assertAccepted(WorldTransaction().replace(id(1), with: circle(1)), against: joined)
        XCTAssertEqual(Set(kept.state.joints.keys), [joint(1)])
        XCTAssertEqual(kept.removedJointIDs, [])
    }

    // MARK: Istnienie ciał i identyfikatorów więzów

    func testMissingBodyAndNonPhysicalBodyAreRejected() throws {
        let sensor = try SensorDescriptor(id: id(3), position: .zero, geometry: .circle(radius: 1))
        let state = try TransactionStager.stage(WorldTransaction().add(.sensor(sensor)), against: world([box(1), box(2, at: 5)])).state
        assertRejected(WorldTransaction().addJoint(weld(1, 1, 99)), against: state, reason: .objectNotFound(id(99)))
        assertRejected(WorldTransaction().addJoint(weld(1, 99, 1)), against: state, reason: .objectNotFound(id(99)))
        assertRejected(WorldTransaction().addJoint(weld(1, 1, 3)), against: state, reason: .incompatibleObjectKind(id(3)))
    }

    func testDuplicateJointIDAndUnknownRemovalAreRejectedAndRemoveJointUpdatesReceipt() throws {
        let state = try world([box(1), box(2, at: 5), box(3, at: 9)])
        let joined = try TransactionStager.stage(WorldTransaction().addJoint(weld(1, 1, 2)), against: state).state
        assertRejected(WorldTransaction().addJoint(weld(1, 2, 3)), against: joined, reason: .duplicateJointID(joint(1)))
        assertRejected(WorldTransaction().addJoint(weld(1, 1, 2)).addJoint(weld(1, 1, 2)), against: state,
                       index: 1, reason: .duplicateJointID(joint(1)))
        assertRejected(WorldTransaction().removeJoint(joint(7)), against: joined, reason: .jointNotFound(joint(7)))
        assertRejected(WorldTransaction().removeJoint(joint(1)).removeJoint(joint(1)), against: joined, index: 1,
                       reason: .jointNotFound(joint(1)))

        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 4),
            transaction: WorldTransaction().removeJoint(joint(1)))], against: joined)
        XCTAssertTrue(batch.state.joints.isEmpty)
        XCTAssertEqual(batch.frame.transactionReceipts.first?.removedJointIDs, [joint(1)])
        XCTAssertEqual(batch.state.objects.count, 3, "samo usunięcie więzu nie rusza ciał")
        // Ten sam identyfikator można użyć ponownie po usunięciu.
        let reused = try assertAccepted(WorldTransaction().removeJoint(joint(1)).addJoint(weld(1, 2, 3)), against: joined)
        XCTAssertEqual(reused.state.joints[joint(1)]?.bodyA, id(2))
    }

    // MARK: Usuwanie więzów razem z ciałami

    func testRemovingBodyRemovesItsJointsAndReceiptListsThemSortedLeavingOthers() throws {
        let state = try world([box(1), box(2, at: 5), box(3, at: 9), bubble(4, at: 14)])
        let joined = try TransactionStager.stage(WorldTransaction()
            .addJoint(weld(30, 1, 2)).addJoint(hinge(10, 2, nil)).addJoint(distance(20, 3, 2)).addJoint(distance(5, 3, 4)),
            against: state).state
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 1),
            transaction: WorldTransaction().remove(id(2)))], against: joined)
        XCTAssertEqual(Set(batch.state.joints.keys), [joint(5)])
        XCTAssertEqual(batch.frame.transactionReceipts.first?.removedJointIDs, [joint(10), joint(20), joint(30)])
        XCTAssertEqual(batch.frame.transactionReceipts.first?.removedObjectIDs, [id(2)])
    }

    func testReplaceRigidBodiesRemovesJointsOfSources() throws {
        let state = try world([box(1), box(2, at: 5), box(3, at: 9)])
        let joined = try TransactionStager.stage(WorldTransaction().addJoint(weld(1, 1, 2)).addJoint(weld(2, 2, 3)).addJoint(hinge(3, 3, nil)),
            against: state).state
        let replacements = [try RigidBodyDescriptor(id: id(10), vertices: [[0, 0], [1, 0], [0, 1]], motionRole: .dynamic,
                                                    physicsMaterialID: rigidMaterial, renderMaterialID: styleID)]
        let change = try assertAccepted(WorldTransaction().replaceRigidBodies([id(1), id(2)], with: replacements), against: joined)
        XCTAssertEqual(Set(change.state.joints.keys), [joint(3)])
        XCTAssertEqual(change.removedJointIDs, [joint(1), joint(2)])
    }

    func testMergeAndSplitRemoveSourceJointsAndResultDoesNotInheritThem() throws {
        let state = try world([bubble(1), bubble(2, at: 3), box(3, at: 9), bubble(4, at: 20)])
        let joined = try TransactionStager.stage(WorldTransaction()
            .addJoint(distance(1, 1, 3)).addJoint(distance(2, 2, nil)).addJoint(distance(3, 1, 2)).addJoint(distance(4, 4, 3)),
            against: state).state
        let result = BubbleResult(id: id(5), physicsMaterialID: bubbleMaterial, renderMaterialID: styleID)
        let merged = try assertAccepted(WorldTransaction().mergeBubbles([id(1), id(2)], result: result), against: joined)
        XCTAssertEqual(Set(merged.state.joints.keys), [joint(4)])
        XCTAssertEqual(merged.removedJointIDs, [joint(1), joint(2), joint(3)])
        XCTAssertFalse(merged.state.joints.values.contains { $0.bodyA == id(5) || $0.bodyB == id(5) })

        let partA = BubbleSplitPart(result: BubbleResult(id: id(6), physicsMaterialID: bubbleMaterial, renderMaterialID: styleID), share: 0.5)
        let partB = BubbleSplitPart(result: BubbleResult(id: id(7), physicsMaterialID: bubbleMaterial, renderMaterialID: styleID), share: 0.5)
        let split = try assertAccepted(WorldTransaction().splitBubble(id(4), first: partA, second: partB), against: joined)
        XCTAssertEqual(Set(split.state.joints.keys), [joint(1), joint(2), joint(3)])
        XCTAssertEqual(split.removedJointIDs, [joint(4)])
        XCTAssertFalse(split.state.joints.values.contains { [id(6), id(7)].contains($0.bodyA) || [id(6), id(7)].contains($0.bodyB ?? id(0)) })
    }

    func testJointAddedAndBodyRemovedInOneTransactionIsListedOnce() throws {
        let state = try world([box(1), box(2, at: 5)])
        let change = try assertAccepted(WorldTransaction().addJoint(weld(1, 1, 2)).remove(id(1)), against: state)
        XCTAssertTrue(change.state.joints.isEmpty)
        XCTAssertEqual(change.removedJointIDs, [joint(1)])
    }
}
