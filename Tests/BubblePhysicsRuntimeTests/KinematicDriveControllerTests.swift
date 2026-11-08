import BubblePhysics
@testable import BubblePhysicsRuntime
import XCTest

/// P-B-16 (G6-AC1): `MotionControllers.prepare` zamienia `KinematicDrive` na narzuconą prędkość; bez sił i bez blokady.
final class KinematicDriveControllerTests: XCTestCase {
    private let duration = 1.0 / 60
    private let kinematicID = ObjectID(rawValue: 1)

    private func seeded(drive: KinematicDrive?, force: WorldPoint = [0, -500]) throws -> RuntimeState {
        let materialID = PhysicsMaterialID(rawValue: 2), styleID = RenderStyleID(rawValue: 1)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .polygon))
            .updateRenderStyle(styleID, style: try RenderStyle())
            .add(.polygon(try PolygonDescriptor(id: kinematicID, vertices: [[0, 0], [2, 0], [2, 2], [0, 2]],
                position: [10, 20], motionRole: .kinematic, physicsMaterialID: materialID, renderStyleID: styleID)))
        if let drive { transaction = transaction.setKinematicDrive(kinematicID, drive: drive) }
        var state = RuntimeState(configuration: try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [-1000, -1000], max: [1000, 1000]), globalForce: force))
        state = try TransactionStager.stage(transaction, against: state).state
        return state
    }

    func testObjectWithoutDriveStandsStillDespiteGlobalForce() throws {
        var state = try seeded(drive: nil)
        try MotionControllers.prepare(&state, duration: duration)
        XCTAssertEqual(state.objects[kinematicID]?.velocity, .zero)
        XCTAssertEqual(state.objects[kinematicID]?.angularVelocity, 0)
    }

    func testVelocityDriveIgnoresGlobalForceAndKeepsPoseExactOverManySteps() throws {
        var state = try seeded(drive: .velocity(linear: [40, -3], angular: 0.7))
        let start = try XCTUnwrap(state.objects[kinematicID])
        let steps = 600
        for _ in 0..<steps {
            try MotionControllers.prepare(&state, duration: duration)
            var object = try XCTUnwrap(state.objects[kinematicID])
            // Solver wykonuje narzuconą prędkość: Float += v·dt.
            object.position += object.velocity * Float(duration)
            object.rotation += object.angularVelocity * Float(duration)
            state.objects[kinematicID] = object
        }
        let time = Float(Double(steps) * duration)
        let end = try XCTUnwrap(state.objects[kinematicID])
        XCTAssertEqual(end.position.x, start.position.x + 40 * time, accuracy: 1e-4)
        XCTAssertEqual(end.position.y, start.position.y - 3 * time, accuracy: 1e-4)
        XCTAssertEqual(end.rotation, start.rotation + 0.7 * time, accuracy: 1e-4)
    }

    func testTargetDriveSetsVelocityThatReachesPoseInOneStep() throws {
        var state = try seeded(drive: .target(position: [30, 25], rotation: 0.5))
        try MotionControllers.prepare(&state, duration: duration)
        let object = try XCTUnwrap(state.objects[kinematicID])
        XCTAssertEqual(object.velocity.x * Float(duration), 20, accuracy: 1e-4)
        XCTAssertEqual(object.velocity.y * Float(duration), 5, accuracy: 1e-4)
        XCTAssertEqual(object.angularVelocity * Float(duration), 0.5, accuracy: 1e-6)
    }

    func testPathDriveHeadsForWaypointAtDeclaredSpeedAndStopsOnArrival() throws {
        var state = try seeded(drive: .path(PathDrive(points: [[10, 50]], speed: 30)))
        try MotionControllers.prepare(&state, duration: duration)
        XCTAssertEqual(state.objects[kinematicID]?.velocity.y ?? 0, 30, accuracy: 1e-4)
        XCTAssertEqual(state.objects[kinematicID]?.velocity.x ?? 1, 0, accuracy: 1e-4)
        state.objects[kinematicID]?.position = [10, 50]
        try MotionControllers.prepare(&state, duration: duration)
        XCTAssertEqual(state.objects[kinematicID]?.velocity, .zero)
    }

    func testPoseChangedOutsideTheTrackReseedsTheExactPose() throws {
        var state = try seeded(drive: .velocity(linear: [10, 0], angular: 0))
        try MotionControllers.prepare(&state, duration: duration)
        state.objects[kinematicID]?.position = [500, 500] // np. wrap regionu
        try MotionControllers.prepare(&state, duration: duration)
        let object = try XCTUnwrap(state.objects[kinematicID])
        XCTAssertEqual(object.velocity.x, 10, accuracy: 1e-3)
        XCTAssertEqual(object.velocity.y, 0, accuracy: 1e-3)
    }
}
