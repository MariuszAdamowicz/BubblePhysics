import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// Materiał bańki 4.0.0 to tylko sztywność kontaktu K_c i opór γ (G1-AC1, G1-AC3, CD-D-11).
final class BubbleMaterialTests: XCTestCase {
    private let style = RenderMaterialID(rawValue: 1)
    private let bubbleMaterial = PhysicsMaterialID(rawValue: 1), rigidMaterial = PhysicsMaterialID(rawValue: 2)

    private func assertOutOfRange(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ build: () throws -> PhysicsMaterial) {
        XCTAssertThrowsError(try build(), name, file: file, line: line) {
            XCTAssertEqual($0 as? ModelValidationError, .valueOutOfRange(name), file: file, line: line)
        }
    }

    // MARK: P-B-1, materiał

    func testBubbleMaterialHoldsStiffnessAndDamping() throws {
        let material = try PhysicsMaterial(kind: .bubble, contactStiffness: 229, damping: 1)
        XCTAssertEqual(material.contactStiffness, 229)
        XCTAssertEqual(material.damping, 1)
        XCTAssertEqual(material.friction, 0)
        XCTAssertEqual(material.restitution, 0)
        XCTAssertNil(material.maximumLinearSpeed)
        XCTAssertNil(material.maximumAngularSpeed)
        XCTAssertEqual(try PhysicsMaterial(kind: .bubble, contactStiffness: 229).damping, 0)
    }

    func testBubbleStiffnessIsRequiredPositiveAndFinite() {
        assertOutOfRange("contactStiffness") { try PhysicsMaterial(kind: .bubble) }
        for value in [Float(0), -1, -229, .nan, .infinity, -.infinity] {
            assertOutOfRange("contactStiffness") { try PhysicsMaterial(kind: .bubble, contactStiffness: value) }
        }
    }

    func testBubbleDampingMustBeNonnegativeAndFinite() throws {
        for value in [Float(-1), -1e-6, .nan, .infinity, -.infinity] {
            assertOutOfRange("damping") { try PhysicsMaterial(kind: .bubble, contactStiffness: 229, damping: value) }
        }
        XCTAssertNoThrow(try PhysicsMaterial(kind: .bubble, contactStiffness: 229, damping: 0))
    }

    func testBubbleMaterialRejectsFrictionRestitutionAndSpeedLimits() {
        assertOutOfRange("friction") { try PhysicsMaterial(kind: .bubble, contactStiffness: 229, friction: 0.5) }
        assertOutOfRange("restitution") { try PhysicsMaterial(kind: .bubble, contactStiffness: 229, restitution: 0.5) }
        assertOutOfRange("maximumLinearSpeed") { try PhysicsMaterial(kind: .bubble, contactStiffness: 229, maximumLinearSpeed: 600) }
        assertOutOfRange("maximumAngularSpeed") { try PhysicsMaterial(kind: .bubble, contactStiffness: 229, maximumAngularSpeed: 6) }
    }

    // MARK: P-B-3, materiał sztywny jak w v3.0.2

    func testRigidMaterialKeepsFrictionRestitutionLimitsAndDamping() throws {
        let material = try PhysicsMaterial(kind: .rigid, damping: 0.5, friction: 0.7, restitution: 0.3,
                                           maximumLinearSpeed: 40, maximumAngularSpeed: 5)
        XCTAssertEqual([material.damping, material.friction, material.restitution], [0.5, 0.7, 0.3])
        XCTAssertEqual(material.maximumLinearSpeed, 40)
        XCTAssertEqual(material.maximumAngularSpeed, 5)
        XCTAssertNil(material.contactStiffness)
        XCTAssertNoThrow(try PhysicsMaterial(kind: .rigid))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .rigid, friction: -1))
        XCTAssertThrowsError(try PhysicsMaterial(kind: .rigid, restitution: 1.5)) {
            XCTAssertEqual($0 as? ModelValidationError, .valueOutOfRange("restitution"))
        }
        XCTAssertThrowsError(try PhysicsMaterial(kind: .rigid, maximumLinearSpeed: 0))
    }

    func testRigidMaterialRejectsContactStiffness() {
        assertOutOfRange("contactStiffness") { try PhysicsMaterial(kind: .rigid, contactStiffness: 229) }
    }

    // MARK: P-B-1, przejścia materiału

    private func state() throws -> RuntimeState {
        try TransactionStager.stage(WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble, contactStiffness: 200, damping: 1))
            .updatePhysicsMaterial(rigidMaterial, material: PhysicsMaterial(kind: .rigid, friction: 0.4))
            .updateRenderMaterial(style, material: RenderMaterial()),
            against: RuntimeState(configuration: WorldConfiguration(simulationRegion:
                WorldRectangle(min: [-20, -20], max: [20, 20])))).state
    }

    private func transition(_ id: PhysicsMaterialID, _ parameter: PhysicsParameter, to value: Float) -> WorldTransaction {
        WorldTransaction().startTransition(.init(target: .physicsMaterial(id, parameter), value: .scalar(value), duration: 1))
    }

    func testBubbleTransitionsReachStiffnessAndDamping() throws {
        var current = try state()
        current = try TransactionStager.stage(transition(bubbleMaterial, .contactStiffness, to: 400), against: current).state
        current = try TransactionStager.stage(transition(bubbleMaterial, .damping, to: 5), against: current).state
        try MotionControllers.prepare(&current, duration: 0.5)
        XCTAssertEqual(try XCTUnwrap(current.physicsMaterials[bubbleMaterial]?.contactStiffness), 300, accuracy: 1e-3)
        XCTAssertEqual(try XCTUnwrap(current.physicsMaterials[bubbleMaterial]?.damping), 3, accuracy: 1e-5)
        try MotionControllers.prepare(&current, duration: 0.5)
        XCTAssertEqual(current.physicsMaterials[bubbleMaterial]?.contactStiffness, 400)
        XCTAssertEqual(current.physicsMaterials[bubbleMaterial]?.damping, 5)
        XCTAssertNil(current.physicsMaterials[bubbleMaterial]?.maximumLinearSpeed)
    }

    func testBubbleTransitionsToFrictionRestitutionAndNonpositiveStiffnessAreRejected() throws {
        let current = try state()
        let invalid: [(PhysicsParameter, Float)] = [(.friction, 0.5), (.restitution, 0.5), (.contactStiffness, 0), (.contactStiffness, -3)]
        for (parameter, value) in invalid {
            XCTAssertThrowsError(try TransactionStager.stage(transition(bubbleMaterial, parameter, to: value), against: current),
                                 "\(parameter) \(value)") {
                guard let rejection = $0 as? TransactionRejection, case .invalidValue(.valueOutOfRange) = rejection.reason else {
                    return XCTFail("zły błąd \($0)")
                }
            }
        }
    }

    func testRigidMaterialTransitionsKeepFrictionAndRejectStiffness() throws {
        var current = try state()
        current = try TransactionStager.stage(transition(rigidMaterial, .friction, to: 0.8), against: current).state
        try MotionControllers.prepare(&current, duration: 0.5)
        XCTAssertEqual(try XCTUnwrap(current.physicsMaterials[rigidMaterial]?.friction), 0.6, accuracy: 1e-6)
        XCTAssertThrowsError(try TransactionStager.stage(transition(rigidMaterial, .contactStiffness, to: 229), against: current)) {
            guard let rejection = $0 as? TransactionRejection, case .invalidValue(.valueOutOfRange) = rejection.reason else {
                return XCTFail("zły błąd \($0)")
            }
        }
    }
}
