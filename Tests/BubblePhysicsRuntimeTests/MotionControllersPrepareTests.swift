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

    /// Deterministyczny generator (xorshift), by zestawy identyfikatorów były powtarzalne między uruchomieniami.
    private struct Sequence64 {
        var value: UInt64
        mutating func next(below bound: Int) -> Int {
            value ^= value << 13; value ^= value >> 7; value ^= value << 17
            return Int(value % UInt64(bound))
        }
    }

    func testTheErrorComesFromTheObjectWithTheSmallestIDRegardlessOfDictionaryOrder() throws {
        var random = Sequence64(value: 0x9E37_79B9_7F4A_7C15)
        // Rozmiary słownika i położenia uszkodzonych identyfikatorów zmieniają kolejność iteracji między przypadkami.
        for trial in 0..<48 {
            let size = 2 + random.next(below: 79)
            let first = 1 + random.next(below: size), second = 1 + random.next(below: size)
            guard first != second else { continue }
            let small = min(first, second), large = max(first, second)
            // Przy naprzemiennych rodzajach uszkodzenia błąd wskazuje, który obiekt został zgłoszony.
            let smallBreaksVelocity = trial.isMultiple(of: 2)
            var prepared = try state(bodies: size)
            if smallBreaksVelocity {
                prepared.objects[ObjectID(rawValue: UInt64(small))]?.velocity = [.nan, 0]
                prepared.objects[ObjectID(rawValue: UInt64(large))]?.angularVelocity = .infinity
            } else {
                prepared.objects[ObjectID(rawValue: UInt64(small))]?.angularVelocity = .infinity
                prepared.objects[ObjectID(rawValue: UInt64(large))]?.velocity = [.nan, 0]
            }
            let expected = ModelValidationError.nonFiniteValue(smallBreaksVelocity ? "motion.velocity" : "motion.angularVelocity")
            XCTAssertThrowsError(try MotionControllers.prepare(&prepared, duration: duration),
                                 "rozmiar \(size), uszkodzone \(small) i \(large)") { error in
                XCTAssertEqual(error as? ModelValidationError, expected, "rozmiar \(size), uszkodzone \(small) i \(large)")
            }
        }
    }
}
