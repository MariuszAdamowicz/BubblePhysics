import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-23 po stronie runtime: moment silnika `motorDriven` dzieli przez inercję liczoną z `RigidShape`.
final class RigidInertiaControllerTests: XCTestCase {
    private let duration = 1.0 / 60
    private let materialID = PhysicsMaterialID(rawValue: 2), styleID = RenderStyleID(rawValue: 1)

    private func angularVelocityAfterOneStep(shape: RigidShape, mass: Float, inertia: Float?, torque: Float) throws -> Float {
        let id = ObjectID(rawValue: 1)
        let body = try RigidBodyDescriptor(id: id, shape: shape, mass: mass, momentOfInertia: inertia,
            motionRole: .dynamic, physicsMaterialID: materialID, renderStyleID: styleID)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderStyle(styleID, style: try RenderStyle())
            .add(.rigidBody(body))
        transaction = transaction.setMotorDrive(id, drive: try MotorDrive(torque: torque))
        var state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-100, -100], max: [100, 100])))
        state = try TransactionStager.stage(transaction, against: state).state
        try MotionControllers.prepare(&state, duration: duration)
        return try XCTUnwrap(state.objects[id]).angularVelocity
    }

    func testMotorTorqueUsesInertiaComputedFromShapeAndSuppliedInertiaWins() throws {
        // Koło m = 4, r = 2: I = m·r²/2 = 8, więc Δω = M / I · dt.
        let computed = try angularVelocityAfterOneStep(shape: .circle(radius: 2), mass: 4, inertia: nil, torque: 16)
        XCTAssertEqual(computed, 16 / 8 * Float(duration), accuracy: 1e-6)
        let supplied = try angularVelocityAfterOneStep(shape: .circle(radius: 2), mass: 4, inertia: 32, torque: 16)
        XCTAssertEqual(supplied, 16 / 32 * Float(duration), accuracy: 1e-6)
        // Kapsuła: inercja większa niż koła o tym samym promieniu i masie, więc przyspiesza wolniej.
        let capsule = try angularVelocityAfterOneStep(shape: .capsule(halfLength: 3, radius: 2), mass: 4, inertia: nil, torque: 16)
        XCTAssertLessThan(capsule, computed)
        XCTAssertEqual(capsule, 16 / RigidShape.capsule(halfLength: 3, radius: 2).momentOfInertia(mass: 4) * Float(duration),
                       accuracy: 1e-6)
    }
}
