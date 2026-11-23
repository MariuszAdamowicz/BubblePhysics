@testable import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// Wykluczenie baniek i brył dynamicznych z jednego świata (P-B-38, G7-AC4, CD-D-2): transakcja, po której świat zawierałby
/// bańkę i bryłę w roli `.dynamic`, `.motorDriven`, `.playerDriven` albo `.pathDriven`, jest odrzucana błędem
/// „nieobsługiwane w 4.0.0” przez `NativeCompleteStepper.validate(_:)`, a świat zostaje bez zmian. Reguła patrzy na stan po
/// całej transakcji, więc nie zależy od tego, która operacja wprowadziła bryłę. Bez GPU.
@MainActor
final class DynamicRigidExclusionTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let style = RenderMaterialID(rawValue: 1)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private let reason = TransactionRejectionReason.unsupportedBubbleWithDynamicRigidBody

    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble, contactStiffness: 1e9))
            .updatePhysicsMaterial(rigidMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: try RenderMaterial())
    }
    private func bubble(_ value: UInt64, at position: WorldPoint = [-50, 0], role: MotionRole = .dynamic) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: position, targetRadius: 2, mass: 2, motionRole: role,
                                     physicsMaterialID: bubbleMaterial, renderMaterialID: style))
    }
    private func bodyDescriptor(_ value: UInt64, role: MotionRole, at position: WorldPoint = [50, 0]) throws -> RigidBodyDescriptor {
        try RigidBodyDescriptor(id: id(value), shape: .circle(radius: 3), position: position, motionRole: role,
                                physicsMaterialID: rigidMaterial, renderMaterialID: style)
    }
    private func body(_ value: UInt64, role: MotionRole, at position: WorldPoint = [50, 0]) throws -> WorldObject {
        .rigidBody(try bodyDescriptor(value, role: role, at: position))
    }

    private func initialState(_ transaction: WorldTransaction) throws -> RuntimeState {
        let stepper = try NativeCompleteStepper(device: nil)
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 1), transaction: transaction)],
            against: RuntimeState(configuration: try WorldConfiguration(
                simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100]))), validate: stepper.validate)
        XCTAssertEqual(batch.frame.transactionReceipts.count, 1, "przygotowanie sceny musi zostać przyjęte: \(batch.frame.events)")
        return batch.state
    }
    private func stage(_ transaction: WorldTransaction, against initial: RuntimeState) throws -> StagedTransactionBatch {
        let stepper = try NativeCompleteStepper(device: nil)
        return TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 2), transaction: transaction)],
                                            against: initial, validate: stepper.validate)
    }
    private func assertRejected(_ transaction: WorldTransaction, against initial: RuntimeState, index: Int = 0, _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let batch = try stage(transaction, against: initial)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 2),
            TransactionRejection(operationIndex: index, reason: reason))], name, file: file, line: line)
        XCTAssertTrue(batch.frame.transactionReceipts.isEmpty, name, file: file, line: line)
        XCTAssertEqual(batch.state, initial, "\(name): świat bez zmian", file: file, line: line)
    }
    private func assertAccepted(_ transaction: WorldTransaction, against initial: RuntimeState, _ name: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let batch = try stage(transaction, against: initial)
        XCTAssertEqual(batch.frame.transactionReceipts.count, 1, "\(name): \(batch.frame.events)", file: file, line: line)
        XCTAssertNotEqual(batch.state, initial, name, file: file, line: line)
    }

    private let dynamicRoles: [MotionRole] = [.dynamic, .motorDriven, .playerDriven, .pathDriven]

    // MARK: wstawienie

    func testAddingADynamicBodyToAWorldWithBubblesIsRejectedForEveryDynamicRole() throws {
        let initial = try initialState(resources().add(bubble(1)))
        for role in dynamicRoles {
            try assertRejected(WorldTransaction().add(try body(100, role: role)), against: initial, "bryła \(role)")
        }
    }

    func testAddingABubbleToAWorldWithADynamicBodyIsRejectedForEveryDynamicRole() throws {
        for role in dynamicRoles {
            let initial = try initialState(resources().add(body(100, role: role)))
            try assertRejected(WorldTransaction().add(try bubble(1)), against: initial, "bańka przy bryle \(role)")
        }
    }

    func testStaticAndKinematicBodiesShareAWorldWithBubbles() throws {
        let initial = try initialState(resources().add(bubble(1)))
        try assertAccepted(WorldTransaction().add(try body(100, role: .static)), against: initial, "bryła statyczna")
        try assertAccepted(WorldTransaction().add(try body(100, role: .kinematic)), against: initial, "bryła kinematyczna")
        let withBodies = try initialState(resources().add(body(100, role: .static)).add(body(101, role: .kinematic, at: [60, 0])))
        try assertAccepted(WorldTransaction().add(try bubble(1)), against: withBodies, "bańka przy bryłach statycznej i kinematycznej")
    }

    /// Świat z samymi bryłami dynamicznymi i świat z samymi bańkami działają jak dotąd (CD-D-2).
    func testWorldsWithOnlyDynamicBodiesOrOnlyBubblesAreAccepted() throws {
        let bodies = try initialState(resources().add(body(100, role: .dynamic)))
        try assertAccepted(WorldTransaction().add(try body(101, role: .motorDriven, at: [60, 0])), against: bodies, "więcej brył dynamicznych")
        try assertAccepted(WorldTransaction().add(try body(101, role: .static, at: [60, 0])), against: bodies, "bryła statyczna")
        let bubbles = try initialState(resources().add(bubble(1)))
        try assertAccepted(WorldTransaction().add(try bubble(2, at: [-20, 0])), against: bubbles, "więcej baniek")
    }

    // MARK: replace, replaceRigidBodies, setMotion

    func testReplacingABodyWithADynamicOneInAWorldWithBubblesIsRejected() throws {
        let initial = try initialState(resources().add(bubble(1)).add(body(100, role: .static)))
        try assertRejected(WorldTransaction().replace(id(100), with: try body(100, role: .dynamic)), against: initial, "replace")
        try assertAccepted(WorldTransaction().replace(id(100), with: try body(100, role: .kinematic)), against: initial,
                           "replace na kinematyczną")
    }

    func testReplaceRigidBodiesWithADynamicResultInAWorldWithBubblesIsRejected() throws {
        let initial = try initialState(resources().add(bubble(1)).add(body(100, role: .static)).add(body(101, role: .static, at: [60, 0])))
        try assertRejected(WorldTransaction().replaceRigidBodies([id(100), id(101)], with: [
            try bodyDescriptor(102, role: .static), try bodyDescriptor(103, role: .dynamic, at: [60, 0])]),
            against: initial, "replaceRigidBodies")
        try assertAccepted(WorldTransaction().replaceRigidBodies([id(100), id(101)], with: [
            try bodyDescriptor(102, role: .static), try bodyDescriptor(103, role: .kinematic, at: [60, 0])]),
            against: initial, "replaceRigidBodies bez dynamicznej")
    }

    func testChangingABodyRoleToDynamicInAWorldWithBubblesIsRejected() throws {
        let initial = try initialState(resources().add(bubble(1)).add(body(100, role: .static)))
        for role in [MotionRole.dynamic, .motorDriven, .pathDriven] {
            try assertRejected(WorldTransaction().setMotion(id(100), role: role), against: initial, "setMotion \(role)")
        }
        try assertAccepted(WorldTransaction().setMotion(id(100), role: .kinematic), against: initial, "setMotion kinematic")
    }

    func testChangingABubbleRoleIsAllowedBecauseTheRuleIsAboutBodies() throws {
        let initial = try initialState(resources().add(bubble(1)))
        try assertAccepted(WorldTransaction().setMotion(id(1), role: .static), against: initial, "bańka na statyczną")
    }

    // MARK: stan po całej transakcji

    func testRuleLooksAtTheStateAfterTheWholeTransactionAndReportsTheLastOperation() throws {
        let initial = try initialState(resources().add(body(100, role: .dynamic)))
        // Dynamiczna bryła znika w tej samej transakcji, w której wchodzi bańka: stan po partii jest poprawny.
        try assertAccepted(WorldTransaction().remove(id(100)).add(try bubble(1)), against: initial, "usunięcie bryły i bańka")
        // Odwrotnie: bańka wchodzi, a bryła zostaje, więc koniec transakcji jest niedozwolony; indeks to ostatnia operacja.
        try assertRejected(WorldTransaction().add(try bubble(1)).setGlobalForce([0, -1]), against: initial, index: 1,
                           "bańka obok bryły i niezwiązana operacja")
        // Bańka i bryła dynamiczna dodane razem w świecie bez nich.
        let empty = try initialState(resources())
        try assertRejected(WorldTransaction().add(try bubble(1)).add(try body(100, role: .dynamic)), against: empty, index: 1,
                           "dwie operacje")
        try assertAccepted(WorldTransaction().add(try bubble(1)).add(try body(100, role: .dynamic)).remove(id(100)), against: empty,
                           "bryła dodana i usunięta")
    }

    func testRejectionDoesNotStopTheNextTransactionInTheBatch() throws {
        let initial = try initialState(resources().add(bubble(1)))
        let stepper = try NativeCompleteStepper(device: nil)
        let batch = TransactionStager.stageBatch([
            PendingTransaction(token: TransactionToken(rawValue: 5), transaction: WorldTransaction().add(try body(100, role: .dynamic))),
            PendingTransaction(token: TransactionToken(rawValue: 6), transaction: WorldTransaction().add(try body(101, role: .static))),
        ], against: initial, validate: stepper.validate)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 5),
            TransactionRejection(operationIndex: 0, reason: reason))])
        XCTAssertEqual(batch.frame.transactionReceipts.map(\.token.rawValue), [6])
        XCTAssertNil(batch.state.objects[id(100)])
        XCTAssertNotNil(batch.state.objects[id(101)])
    }
}
