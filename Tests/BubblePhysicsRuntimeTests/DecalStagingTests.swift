import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-48, P-B-49: naklejki w stagerze. Odrzucona transakcja niczego nie zmienia, a wynik scalenia i podziału bierze
/// naklejkę z `BubbleResult`. Rejestr zasobów podaje stagerowi tylko domknięcia (tekstury i glify).
final class DecalStagingTests: XCTestCase {
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private let look = RenderMaterialID(rawValue: 1)
    private let font = FontID(rawValue: 3)
    private let otherFont = FontID(rawValue: 33)
    private let atlas = GlyphAtlasID(rawValue: 4)
    private let otherAtlas = GlyphAtlasID(rawValue: 44)
    private let known = TextureID(rawValue: 7)
    private let unknown = TextureID(rawValue: 8)
    private func id(_ value: UInt64) -> ObjectID { ObjectID(rawValue: value) }

    private func exists(_ texture: TextureID) -> Bool { texture == known }
    /// Czcionka 3 ma cyfry, atlas 4 ma "AB"; reszta źródeł nie istnieje.
    private func glyphs(_ source: GlyphSource) -> ((Character) -> Bool)? {
        switch source {
        case .font(let value) where value == font: return { "0123456789".contains($0) }
        case .atlas(let value) where value == atlas: return { "AB".contains($0) }
        default: return nil
        }
    }

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
    private func digits(_ text: String = "123") throws -> Decal { try .text(text, source: .font(font), color: RGBA(1, 0, 0, 1), scale: 0.5) }
    private func letters(_ text: String = "AB") throws -> Decal { try .text(text, source: .atlas(atlas)) }
    private func picture() throws -> Decal {
        try .image(known, region: TextureRegion(min: [0.25, 0.25], max: [0.75, 0.5]), scale: 2)
    }
    private func bubble(_ value: UInt64, decal: Decal? = nil) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: id(value), position: .zero, targetRadius: 2, mass: 2,
            physicsMaterialID: bubbleMaterial, renderMaterialID: look, decal: decal))
    }
    private func box(_ value: UInt64, decal: Decal? = nil) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: id(value), vertices: [[0, 0], [2, 0], [0, 2]],
            physicsMaterialID: rigidMaterial, renderMaterialID: look, decal: decal))
    }
    private func staged(_ transaction: WorldTransaction, against state: RuntimeState) throws -> StagedWorldChange {
        try TransactionStager.stage(transaction, against: state, textureExists: exists, glyphLookup: glyphs)
    }
    private func assertRejected(_ transaction: WorldTransaction, against state: RuntimeState, at index: Int,
                                reason: TransactionRejectionReason, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try staged(transaction, against: state), file: file, line: line) {
            XCTAssertEqual($0 as? TransactionRejection, TransactionRejection(operationIndex: index, reason: reason),
                           file: file, line: line)
        }
    }

    // MARK: model

    func testDecalValidatesScaleColorAndRegion() throws {
        for scale in [Float(0), -1, .nan, .infinity] {
            XCTAssertThrowsError(try Decal.text("1", source: .font(font), scale: scale), "skala \(scale)")
        }
        XCTAssertThrowsError(try Decal.text("1", source: .font(font), color: RGBA(1, 2, 0, 1)))
        XCTAssertThrowsError(try Decal.image(known, color: RGBA(.nan, 0, 0, 1)))
        XCTAssertThrowsError(try TextureRegion(min: [0.5, 0], max: [0.5, 1]), "pusty prostokąt")
        XCTAssertThrowsError(try TextureRegion(min: [-0.1, 0], max: [1, 1]))
        XCTAssertThrowsError(try TextureRegion(min: [0, 0], max: [1.1, 1]))
        XCTAssertThrowsError(try TextureRegion(min: [0, .nan], max: [1, 1]))
        XCTAssertNoThrow(try TextureRegion(min: [0, 0], max: [1, 1]))
        XCTAssertEqual(TextureRegion.full, try TextureRegion(min: [0, 0], max: [1, 1]))
    }

    // MARK: przyjęcie i odrzucenie

    func testObjectStartsWithTheDecalOfItsDescriptor() throws {
        let text = try digits(), image = try picture()
        let current = try staged(resources().add(bubble(1, decal: text)).add(box(2, decal: image)).add(bubble(3)),
                                 against: state()).state
        XCTAssertEqual(current.objects[id(1)]?.decal, text)
        XCTAssertEqual(current.objects[id(2)]?.decal, image)
        XCTAssertNil(current.objects[id(3)]?.decal)
    }

    func testCharacterOutsideTheGlyphSetIsRejectedWithThatCharacter() throws {
        let initial = try staged(resources().add(bubble(1)), against: state()).state
        let bad = try digits("12x3")
        try assertRejected(WorldTransaction().add(bubble(2, decal: bad)), against: initial, at: 0,
                           reason: .characterNotInGlyphSet("x"))
        assertRejected(WorldTransaction().setDecal(id(1), decal: bad), against: initial, at: 0,
                       reason: .characterNotInGlyphSet("x"))
        try assertRejected(WorldTransaction().setDecal(id(1), decal: .text("AC", source: .atlas(atlas))), against: initial,
                           at: 0, reason: .characterNotInGlyphSet("C"))
        XCTAssertNoThrow(try staged(WorldTransaction().setDecal(id(1), decal: letters("ABBA")), against: initial))
    }

    func testUnknownFontAndAtlasAreRejected() throws {
        let initial = try staged(resources().add(bubble(1)), against: state()).state
        try assertRejected(WorldTransaction().setDecal(id(1), decal: .text("1", source: .font(otherFont))),
                           against: initial, at: 0, reason: .fontNotFound(otherFont))
        try assertRejected(WorldTransaction().setDecal(id(1), decal: .text("A", source: .atlas(otherAtlas))),
                           against: initial, at: 0, reason: .glyphAtlasNotFound(otherAtlas))
    }

    func testImageDecalWithAnUnregisteredTextureIsRejected() throws {
        let initial = try staged(resources().add(bubble(1)), against: state()).state
        assertRejected(try WorldTransaction().setDecal(id(1), decal: .image(unknown)), against: initial, at: 0,
                       reason: .textureNotFound(unknown))
        try assertRejected(WorldTransaction().add(box(2, decal: .image(unknown))), against: initial, at: 0,
                           reason: .textureNotFound(unknown))
        XCTAssertNoThrow(try staged(WorldTransaction().setDecal(id(1), decal: .image(known)), against: initial))
    }

    func testEmptyTextNeedsARegisteredSourceButNoCharacters() throws {
        let initial = try staged(resources().add(bubble(1)), against: state()).state
        XCTAssertNoThrow(try staged(WorldTransaction().setDecal(id(1), decal: .text("", source: .font(font))), against: initial))
        try assertRejected(WorldTransaction().setDecal(id(1), decal: .text("", source: .font(otherFont))), against: initial,
                           at: 0, reason: .fontNotFound(otherFont))
    }

    func testReplacementAndRigidBodyReplacementValidateTheirDecals() throws {
        let initial = try staged(resources().add(bubble(1)).add(box(2)), against: state()).state
        assertRejected(try WorldTransaction().replace(id(1), with: bubble(1, decal: digits("9z"))), against: initial,
                       at: 0, reason: .characterNotInGlyphSet("z"))
        let result = try RigidBodyDescriptor(id: id(3), vertices: [[0, 0], [2, 0], [0, 2]], physicsMaterialID: rigidMaterial,
                                             renderMaterialID: look, decal: .image(unknown))
        assertRejected(WorldTransaction().replaceRigidBodies([id(2)], with: [result]), against: initial, at: 0,
                       reason: .textureNotFound(unknown))
        let accepted = try RigidBodyDescriptor(id: id(3), vertices: [[0, 0], [2, 0], [0, 2]], physicsMaterialID: rigidMaterial,
                                               renderMaterialID: look, decal: letters())
        let replaced = try staged(WorldTransaction().replaceRigidBodies([id(2)], with: [accepted]), against: initial).state
        XCTAssertEqual(replaced.objects[id(3)]?.decal, try letters())
    }

    // MARK: setDecal

    func testSetDecalChangesOnlyTheDecalOfABubbleOrRigidBodyAndNilRemovesIt() throws {
        let initial = try staged(resources().add(bubble(1, decal: digits())).add(box(2)), against: state()).state
        let image = try picture(), text = try letters()
        let changed = try staged(WorldTransaction().setDecal(id(1), decal: image).setDecal(id(2), decal: text), against: initial).state
        XCTAssertEqual(changed.objects[id(1)]?.decal, image)
        XCTAssertEqual(changed.objects[id(2)]?.decal, text)
        var expected = try XCTUnwrap(initial.objects[id(1)])
        expected.decal = image
        XCTAssertEqual(changed.objects[id(1)], expected, "setDecal zmienia tylko naklejkę obiektu")
        XCTAssertEqual(changed.objects[id(1)]?.descriptor, initial.objects[id(1)]?.descriptor)
        let removed = try staged(WorldTransaction().setDecal(id(1), decal: nil), against: changed).state
        XCTAssertNil(removed.objects[id(1)]?.decal)
    }

    func testSetDecalIsRejectedForSensorForceFieldAndUnknownObject() throws {
        let sensor = try SensorDescriptor(id: id(5), position: .zero, geometry: .circle(radius: 1))
        let field = try ForceFieldDescriptor(id: id(6), position: .zero, geometry: .circle(radius: 1),
                                             field: .directional(force: [1, 0]))
        let initial = try staged(resources().add(.sensor(sensor)).add(.forceField(field)), against: state()).state
        let text = try digits()
        assertRejected(WorldTransaction().setDecal(id(5), decal: text), against: initial, at: 0, reason: .decalNotSupported(id(5)))
        assertRejected(WorldTransaction().setDecal(id(6), decal: nil), against: initial, at: 0, reason: .decalNotSupported(id(6)))
        assertRejected(WorldTransaction().setDecal(id(7), decal: text), against: initial, at: 0, reason: .objectNotFound(id(7)))
    }

    func testRejectedTransactionDoesNotChangeTheDecal() throws {
        let original = try digits()
        let initial = try staged(resources().add(bubble(1, decal: original)), against: state()).state
        let transaction = try WorldTransaction().setDecal(id(1), decal: .image(known)).remove(id(999))
        let batch = TransactionStager.stageBatch([PendingTransaction(token: TransactionToken(rawValue: 1), transaction: transaction)],
                                                 against: initial, textureExists: exists, glyphLookup: glyphs)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 1),
            TransactionRejection(operationIndex: 1, reason: .objectNotFound(id(999))))])
        XCTAssertEqual(batch.state.objects[id(1)]?.decal, original)
    }

    func testBatchPassesTheGlyphLookupToEveryTransaction() throws {
        let initial = try staged(resources().add(bubble(1)), against: state()).state
        let good = PendingTransaction(token: TransactionToken(rawValue: 1),
                                      transaction: try WorldTransaction().setDecal(id(1), decal: digits("42")))
        let bad = PendingTransaction(token: TransactionToken(rawValue: 2),
                                     transaction: try WorldTransaction().setDecal(id(1), decal: digits("4b")))
        let batch = TransactionStager.stageBatch([good, bad], against: initial, textureExists: exists, glyphLookup: glyphs)
        XCTAssertEqual(batch.frame.events, [.transactionRejected(TransactionToken(rawValue: 2),
            TransactionRejection(operationIndex: 0, reason: .characterNotInGlyphSet("b")))])
        XCTAssertEqual(batch.state.objects[id(1)]?.decal, try digits("42"))
    }

    // MARK: scalenie i podział

    func testMergeAndSplitResultsTakeTheDecalFromTheBubbleResult() throws {
        let initial = try staged(resources().add(bubble(1, decal: digits())).add(bubble(2)), against: state()).state
        let merged = try staged(WorldTransaction().mergeBubbles([id(1), id(2)],
            result: BubbleResult(id: id(3), physicsMaterialID: bubbleMaterial, renderMaterialID: look, decal: letters())),
            against: initial).state
        XCTAssertEqual(merged.objects[id(3)]?.decal, try letters(), "wynik scalenia ma naklejkę z operacji, nie ze źródeł")
        let split = WorldTransaction().splitBubble(id(3),
            first: BubbleSplitPart(result: BubbleResult(id: id(4), physicsMaterialID: bubbleMaterial, renderMaterialID: look,
                                                        decal: try picture()), share: 0.5),
            second: BubbleSplitPart(result: BubbleResult(id: id(5), physicsMaterialID: bubbleMaterial, renderMaterialID: look),
                                    share: 0.5))
        let separated = try staged(split, against: merged).state
        XCTAssertEqual(separated.objects[id(4)]?.decal, try picture())
        XCTAssertNil(separated.objects[id(5)]?.decal)
    }

    func testMergeAndSplitResultsWithAnInvalidDecalAreRejected() throws {
        let initial = try staged(resources().add(bubble(1)).add(bubble(2)), against: state()).state
        let broken = BubbleResult(id: id(3), physicsMaterialID: bubbleMaterial, renderMaterialID: look,
                                  decal: try .text("A", source: .font(otherFont)))
        assertRejected(WorldTransaction().mergeBubbles([id(1), id(2)], result: broken), against: initial, at: 0,
                       reason: .fontNotFound(otherFont))
        let part = BubbleSplitPart(result: broken, share: 0.5)
        let other = BubbleSplitPart(result: BubbleResult(id: id(4), physicsMaterialID: bubbleMaterial, renderMaterialID: look),
                                    share: 0.5)
        assertRejected(WorldTransaction().splitBubble(id(1), first: part, second: other), against: initial, at: 0,
                       reason: .fontNotFound(otherFont))
    }
}
