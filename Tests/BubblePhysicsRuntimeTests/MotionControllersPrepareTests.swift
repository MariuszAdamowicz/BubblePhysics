import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-80 (etap 8): przygotowanie kroku zapisuje obiekty w miejscu, w kolejności słownika, ale wynik i błąd nie zależą
/// od tej kolejności.
final class MotionControllersPrepareTests: XCTestCase {
    private let duration = 1.0 / 60

    private func state(bodies count: Int) throws -> RuntimeState {
        let materialID = PhysicsMaterialID(rawValue: 2), styleID = RenderMaterialID(rawValue: 1)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(styleID, material: try RenderMaterial())
        for index in 1...count {
            transaction = transaction.add(.rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: UInt64(index)),
                vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], position: [Float(index) * 5, 0], motionRole: .dynamic,
                physicsMaterialID: materialID, renderMaterialID: styleID)))
        }
        let state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000]), globalForce: [0, -10]))
        return try TransactionStager.stage(transaction, against: state).state
    }

    func testEveryDynamicObjectGetsTheGlobalForceImpulse() throws {
        var prepared = try state(bodies: 40)
        let before = prepared
        try MotionControllers.prepare(&prepared, duration: duration)
        for (id, object) in before.objects {
            guard let mass = object.mass else { continue }
            let expected = object.velocity + WorldPoint(0, -10) / mass * Float(duration)
            XCTAssertEqual(prepared.objects[id]?.velocity, expected, "obiekt \(id.rawValue)")
        }
    }

    func testTheErrorComesFromTheObjectWithTheSmallestIDRegardlessOfDictionaryOrder() throws {
        var prepared = try state(bodies: 40)
        // Obiekt 30 psuje prędkość, obiekt 7 prędkość kątową: jak przy przejściu po posortowanych kluczach błąd zgłasza 7.
        prepared.objects[ObjectID(rawValue: 30)]?.velocity = [.nan, 0]
        prepared.objects[ObjectID(rawValue: 7)]?.angularVelocity = .infinity
        XCTAssertThrowsError(try MotionControllers.prepare(&prepared, duration: duration)) { error in
            XCTAssertEqual(error as? ModelValidationError, .nonFiniteValue("motion.angularVelocity"))
        }
        prepared = try state(bodies: 40)
        prepared.objects[ObjectID(rawValue: 7)]?.velocity = [.nan, 0]
        prepared.objects[ObjectID(rawValue: 30)]?.angularVelocity = .infinity
        XCTAssertThrowsError(try MotionControllers.prepare(&prepared, duration: duration)) { error in
            XCTAssertEqual(error as? ModelValidationError, .nonFiniteValue("motion.velocity"))
        }
    }
}
