import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-39, P-B-62, P-B-75: materiały renderu, warstwy i tło w stagerze; odrzucona transakcja niczego nie zmienia.
final class RenderMaterialStagingTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let look = RenderMaterialID(rawValue: 1)
    private let known = TextureID(rawValue: 7)
    private let unknown = TextureID(rawValue: 8)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }
    private func exists(_ texture: TextureID) -> Bool { texture == known }

    private func state() throws -> RuntimeState {
        RuntimeState(configuration: try WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-100, -100], max: [100, 100])))
    }
    private func resources() throws -> WorldTransaction {
        WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: try PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(rigidMaterial, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(look, material: try RenderMaterial())
    }
    private func bubble(_ value: UInt64, layer: Int32 = 0, material: RenderMaterialID? = nil) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: .zero, targetRadius: 2, mass: 2,
            physicsMaterialID: bubbleMaterial, renderMaterialID: material ?? look, layer: layer))
    }
    private func box(_ value: UInt64, layer: Int32 = 0) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), vertices: [[0, 0], [2, 0], [0, 2]],
            physicsMaterialID: rigidMaterial, renderMaterialID: look, layer: layer))
    }
    private func staged(_ transaction: WorldTransaction, against state: RuntimeState) throws -> StagedWorldChange {
        try TransactionStager.stage(transaction, against: state, textureExists: exists)
    }
    private func assertRejected(_ transaction: WorldTransaction, against state: RuntimeState, at index: Int,
                                reason: TransactionRejectionReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try staged(transaction, against: state), file: file, line: line) {
            XCTAssertEqual($0 as? TransactionRejection, TransactionRejection(operationIndex: index, reason: reason),
                           file: file, line: line)
        }
    }

    // MARK: materiały i tekstury

    func testUpdateRenderMaterialStoresAndReplacesTheMaterial() throws {
        let first = try RenderMaterial(color: RGBA(1, 0, 0, 1))
        let second = try RenderMaterial(texture: known, color: RGBA(0, 1, 0, 1), blend: .additive)
        var current = try staged(WorldTransaction().updateRenderMaterial(look, material: first), against: state()).state
        XCTAssertEqual(current.renderMaterials[look], first)
        current = try staged(WorldTransaction().updateRenderMaterial(look, material: second), against: current).state
        XCTAssertEqual(current.renderMaterials, [look: second])
    }

    func testMaterialWithUnregisteredTextureIsRejectedWithoutChange() throws {
        let initial = try staged(resources(), against: state()).state
        let material = try RenderMaterial(texture: unknown)
        assertRejected(WorldTransaction().updateRenderMaterial(RenderMaterialID(rawValue: 5), material: material),
                       against: initial, at: 0, reason: .textureNotFound(unknown))
        let accepted = try RenderMaterial(texture: known)
        XCTAssertNoThrow(try staged(WorldTransaction().updateRenderMaterial(RenderMaterialID(rawValue: 5), material: accepted),
                                    against: initial))
    }

    func testBackgroundIsSetAndClearedAndMustBeRegistered() throws {
        let initial = try state()
        XCTAssertNil(initial.background)
        let set = try staged(WorldTransaction().setBackground(known), against: initial).state
        XCTAssertEqual(set.background, known)
        let cleared = try staged(WorldTransaction().setBackground(nil), against: set).state
        XCTAssertNil(cleared.background)
        assertRejected(WorldTransaction().setBackground(unknown), against: initial, at: 0, reason: .textureNotFound(unknown))
    }

    func testObjectWithUnknownRenderMaterialIsRejected() throws {
        let initial = try staged(resources(), against: state()).state
        let missing = RenderMaterialID(rawValue: 99)
        try assertRejected(WorldTransaction().add(bubble(1, material: missing)), against: initial, at: 0,
                       reason: .renderMaterialNotFound(missing))
        let withObject = try staged(WorldTransaction().add(bubble(1)), against: initial).state
        let replacement = try WorldObject.bubble(BubbleDescriptor(id: id(1), position: .zero, targetRadius: 2, mass: 2,
            physicsMaterialID: bubbleMaterial, renderMaterialID: missing))
        assertRejected(WorldTransaction().replace(id(1), with: replacement), against: withObject, at: 0,
                       reason: .renderMaterialNotFound(missing))
    }

    func testMergeAndSplitResultsWithUnknownRenderMaterialAreRejected() throws {
        let initial = try staged(resources().add(bubble(1)).add(bubble(2)), against: state()).state
        let missing = RenderMaterialID(rawValue: 99)
        let result = BubbleResult(id: id(3), physicsMaterialID: bubbleMaterial, renderMaterialID: missing)
        assertRejected(WorldTransaction().mergeBubbles([id(1), id(2)], result: result), against: initial, at: 0,
                       reason: .renderMaterialNotFound(missing))
        let part = BubbleSplitPart(result: result, share: 0.5)
        let other = BubbleSplitPart(result: BubbleResult(id: id(4), physicsMaterialID: bubbleMaterial, renderMaterialID: look), share: 0.5)
        assertRejected(WorldTransaction().splitBubble(id(1), first: part, second: other), against: initial, at: 0,
                       reason: .renderMaterialNotFound(missing))
    }

    func testRejectedTransactionChangesNeitherMaterialLayerNorBackground() throws {
        let initial = try staged(resources().add(bubble(1)).setBackground(known), against: state()).state
        let changed = try RenderMaterial(color: RGBA(0, 0, 1, 1))
        let transaction = WorldTransaction()
            .updateRenderMaterial(look, material: changed)
            .setLayer(id(1), layer: 9)
            .setBackground(nil)
            .remove(id(999))
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 1), transaction: transaction)],
                                                 against: initial, textureExists: exists)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 1),
            TransactionRejection(operationIndex: 3, reason: .objectNotFound(id(999))))])
        XCTAssertEqual(batch.state.renderMaterials[look], try RenderMaterial())
        XCTAssertEqual(batch.state.objects[id(1)]?.layer, 0)
        XCTAssertEqual(batch.state.background, known)
    }

    // MARK: warstwy

    func testObjectStartsInTheLayerOfItsDescriptor() throws {
        let current = try staged(resources().add(bubble(1, layer: -4)).add(box(2, layer: 6)).add(bubble(3)), against: state()).state
        XCTAssertEqual(current.objects[id(1)]?.layer, -4)
        XCTAssertEqual(current.objects[id(2)]?.layer, 6)
        XCTAssertEqual(current.objects[id(3)]?.layer, 0)
    }

    func testSetLayerChangesOnlyTheLayerOfABubbleOrRigidBody() throws {
        let initial = try staged(resources().add(bubble(1, layer: 2)).add(box(2)), against: state()).state
        let changed = try staged(WorldTransaction().setLayer(id(1), layer: 8).setLayer(id(2), layer: -1), against: initial).state
        XCTAssertEqual(changed.objects[id(1)]?.layer, 8)
        XCTAssertEqual(changed.objects[id(2)]?.layer, -1)
        var expected = try XCTUnwrap(initial.objects[id(1)])
        expected.layer = 8
        XCTAssertEqual(changed.objects[id(1)], expected, "setLayer zmienia tylko warstwę obiektu")
        XCTAssertEqual(changed.objects[id(1)]?.descriptor, initial.objects[id(1)]?.descriptor)
    }

    func testSetLayerIsRejectedForSensorForceFieldAndUnknownObject() throws {
        let sensor = try SensorDescriptor(id: id(5), position: .zero, geometry: .circle(radius: 1))
        let field = try ForceFieldDescriptor(id: id(6), position: .zero, geometry: .circle(radius: 1),
                                             field: .directional(force: [1, 0]))
        let initial = try staged(resources().add(.sensor(sensor)).add(.forceField(field)), against: state()).state
        assertRejected(WorldTransaction().setLayer(id(5), layer: 1), against: initial, at: 0, reason: .layerNotSupported(id(5)))
        assertRejected(WorldTransaction().setLayer(id(6), layer: 1), against: initial, at: 0, reason: .layerNotSupported(id(6)))
        assertRejected(WorldTransaction().setLayer(id(7), layer: 1), against: initial, at: 0, reason: .objectNotFound(id(7)))
    }

    func testMergeAndSplitResultsKeepTheLayerOfTheResult() throws {
        let initial = try staged(resources().add(bubble(1, layer: 1)).add(bubble(2, layer: 2)), against: state()).state
        let merged = try staged(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: BubbleResult(id: id(3), physicsMaterialID: bubbleMaterial, renderMaterialID: look, layer: 5)), against: initial).state
        XCTAssertEqual(merged.objects[id(3)]?.layer, 5)
        let split = WorldTransaction().splitBubble(id(3),
            first: BubbleSplitPart(result: BubbleResult(id: id(4), physicsMaterialID: bubbleMaterial, renderMaterialID: look, layer: -2), share: 0.5),
            second: BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: bubbleMaterial, renderMaterialID: look), share: 0.5))
        let separated = try staged(split, against: merged).state
        XCTAssertEqual(separated.objects[id(4)]?.layer, -2)
        XCTAssertEqual(separated.objects[id(5)]?.layer, 0)
    }

    func testRigidBodyReplacementResultsKeepTheirLayer() throws {
        let initial = try staged(resources().add(box(1, layer: 3)), against: state()).state
        let result = try RigidBodyDescriptor(id: id(2), vertices: [[0, 0], [2, 0], [0, 2]], physicsMaterialID: rigidMaterial,
                                             renderMaterialID: look, layer: 11)
        let replaced = try staged(WorldTransaction().replaceRigidBodies([id(1)], with: [result]), against: initial).state
        XCTAssertEqual(replaced.objects[id(2)]?.layer, 11)
    }
}
