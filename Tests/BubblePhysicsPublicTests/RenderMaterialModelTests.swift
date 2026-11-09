import BubblePhysics
import XCTest

/// Kształt modelu renderu v2: materiał, warstwa, tło i identyfikatory. Walidację i skutki w stagerze sprawdzają testy etapu 5.
final class RenderMaterialModelTests: XCTestCase {
    private let physics = PhysicsMaterialID(rawValue: 1)
    private let material = RenderMaterialID(rawValue: 4)

    func testDefaultRenderMaterialIsOpaqueWhiteWithoutTextureOrOutlineAndAttachedToBubbles() throws {
        let value = try RenderMaterial()
        XCTAssertNil(value.texture)
        XCTAssertEqual(value.color, RGBA(1, 1, 1, 1))
        XCTAssertEqual(value.blend, .opaque)
        XCTAssertEqual(value.outline.width, 0)
        XCTAssertEqual(value.bubbleMapping, .attached)
        XCTAssertEqual(value.uvOffset, .zero)
        XCTAssertEqual(value.uvScale, SIMD2<Float>(1, 1))
    }

    func testRenderMaterialKeepsEveryField() throws {
        let value = try RenderMaterial(texture: TextureID(rawValue: 9), color: RGBA(0.1, 0.2, 0.3, 0.4),
            blend: .additive, outline: RenderOutline(color: RGBA(1, 0, 0, 1), width: 0.25),
            bubbleMapping: .masked, uvOffset: [0.5, -0.5], uvScale: [2, 3])
        XCTAssertEqual(value.texture, TextureID(rawValue: 9))
        XCTAssertEqual(value.color, RGBA(0.1, 0.2, 0.3, 0.4))
        XCTAssertEqual(value.blend, .additive)
        XCTAssertEqual(value.outline, RenderOutline(color: RGBA(1, 0, 0, 1), width: 0.25))
        XCTAssertEqual(value.bubbleMapping, .masked)
        XCTAssertEqual(value.uvOffset, SIMD2<Float>(0.5, -0.5))
        XCTAssertEqual(value.uvScale, SIMD2<Float>(2, 3))
    }

    func testBubbleAndRigidBodyDescriptorsDefaultToLayerZeroAndCarryMaterialAndLayer() throws {
        let plainBubble = try BubbleDescriptor(id: ObjectID(rawValue: 1), position: .zero, targetRadius: 1,
            physicsMaterialID: physics, renderMaterialID: material)
        XCTAssertEqual(plainBubble.layer, 0)
        XCTAssertEqual(plainBubble.renderMaterialID, material)
        XCTAssertEqual(plainBubble.properties.layer, 0)

        let layeredBubble = try BubbleDescriptor(id: ObjectID(rawValue: 2), position: .zero, targetRadius: 1,
            physicsMaterialID: physics, renderMaterialID: material, eventInterest: [.contact],
            filter: CollisionFilter(category: 2, mask: 4), layer: -3)
        XCTAssertEqual(layeredBubble.layer, -3)
        XCTAssertEqual(layeredBubble.properties,
            PhysicsBodyProperties(layer: -3, filter: CollisionFilter(category: 2, mask: 4), eventInterest: [.contact]))

        let body = try RigidBodyDescriptor(id: ObjectID(rawValue: 3), shape: .circle(radius: 1),
            physicsMaterialID: physics, renderMaterialID: material, layer: 12)
        XCTAssertEqual(body.layer, 12)
        XCTAssertEqual(body.renderMaterialID, material)
        XCTAssertEqual(body.properties.layer, 12)
        let polygon = try RigidBodyDescriptor(id: ObjectID(rawValue: 4),
            vertices: [[0, 0], [1, 0], [0, 1]], physicsMaterialID: physics, renderMaterialID: material)
        XCTAssertEqual(polygon.layer, 0)
    }

    func testBubbleResultCarriesRenderMaterialAndLayer() {
        let result = BubbleResult(id: ObjectID(rawValue: 7), physicsMaterialID: physics,
            renderMaterialID: material, layer: 5)
        XCTAssertEqual(result.renderMaterialID, material)
        XCTAssertEqual(result.layer, 5)
        XCTAssertEqual(BubbleResult(id: ObjectID(rawValue: 8), physicsMaterialID: physics,
            renderMaterialID: material).layer, 0)
    }

    func testSensorAndForceFieldDescriptorsHaveNoRenderMaterial() throws {
        // Czujnik i pole sił nie są rysowane, więc ich deskryptory nie przyjmują materiału renderu.
        let sensor = try SensorDescriptor(id: ObjectID(rawValue: 1), position: .zero, geometry: .circle(radius: 1))
        let field = try ForceFieldDescriptor(id: ObjectID(rawValue: 2), position: .zero,
            geometry: .circle(radius: 1), field: .directional(force: [1, 0]))
        XCTAssertEqual(sensor.id, ObjectID(rawValue: 1))
        XCTAssertEqual(field.id, ObjectID(rawValue: 2))
    }

    func testTransactionBuilderRecordsRenderOperationsInOrder() throws {
        let value = try RenderMaterial()
        let texture = TextureID(rawValue: 3)
        let transaction = WorldTransaction()
            .updateRenderMaterial(material, material: value)
            .setLayer(ObjectID(rawValue: 1), layer: 2)
            .setBackground(texture)
            .setBackground(nil)
        XCTAssertEqual(transaction.operations, [
            .updateRenderMaterial(material, value),
            .setLayer(ObjectID(rawValue: 1), 2),
            .setBackground(texture),
            .setBackground(nil)])
    }

    func testRejectionReasonsNameTheMissingResource() {
        XCTAssertEqual(TransactionRejectionReason.renderMaterialNotFound(material),
                       .renderMaterialNotFound(RenderMaterialID(rawValue: 4)))
        XCTAssertNotEqual(TransactionRejectionReason.textureNotFound(TextureID(rawValue: 1)),
                          .textureNotFound(TextureID(rawValue: 2)))
        XCTAssertEqual(TransactionRejectionReason.layerNotSupported(ObjectID(rawValue: 5)),
                       .layerNotSupported(ObjectID(rawValue: 5)))
    }
}
