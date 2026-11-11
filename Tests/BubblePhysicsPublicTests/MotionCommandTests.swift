import BubblePhysics
import XCTest

@MainActor
final class MotionCommandTests: XCTestCase {
    // Odrzucanie player drive albo publikacja feedbacku wyłącznie przez eventy łamie test.
    func testPlayerDrivePublishesFeedbackEachFrameAndEndsWithoutEvents() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-20,-20], max: [20,20])))
        let id = ObjectID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1))))
            .beginPlayerDrive(id, target: [5,0]))
        let first = await world.advance(by: 1.0/60)
        XCTAssertEqual(first.transactionReceipts.count, 1)
        let feedback = try XCTUnwrap(first.driveFeedback.first)
        XCTAssertEqual(feedback.objectID, id)
        XCTAssertEqual(feedback.target, [5,0])
        XCTAssertGreaterThan(feedback.achievedPoint.x, 0)
        XCTAssertLessThan(feedback.achievedPoint.x, 1)
        XCTAssertTrue(first.events.isEmpty)
        let second = await world.advance(by: 1.0/60)
        XCTAssertEqual(second.driveFeedback.first?.playerDriveID, feedback.playerDriveID)
        XCTAssertGreaterThan(try XCTUnwrap(second.driveFeedback.first).achievedPoint.x, feedback.achievedPoint.x)
        world.submit(WorldTransaction().endPlayerDrive(id))
        let end = await world.advance(by: 1.0/60)
        XCTAssertTrue(end.driveFeedback.isEmpty)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }

    func testDriveConfigurationRejectsNonFiniteAndEmptyPaths() throws {
        XCTAssertThrowsError(try PathDrive(points: [], speed: 1))
        XCTAssertThrowsError(try PathDrive(points: [[1,0]], speed: 0))
        XCTAssertThrowsError(try MotorDrive(force: [.infinity,0]))
        XCTAssertThrowsError(try BubbleDrivePolicy(rigidificationDuration: -.infinity))
    }

    func testPlayerDriveUsesDistanceResponsiveSpeedUpToConfiguredMaximum() async throws {
        func achievedX(targetX: Float) async throws -> Float {
            let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
                WorldRectangle(min: [-20,-20], max: [20,20])))
            let id = ObjectID(rawValue: 1)
            let policy = try BubbleDrivePolicy(maximumSpeed: 12, distanceResponse: 6)
            let transaction = try WorldTransaction()
                .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
                .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
                .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 0.5,
                    physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1), drivePolicy: policy)))
                .beginPlayerDrive(id, target: [targetX, 0])
            world.submit(transaction)
            let frame = await world.advance(by: 1.0 / 60)
            return try XCTUnwrap(frame.driveFeedback.first?.achievedPoint.x)
        }

        let near = try await achievedX(targetX: 0.5)
        let far = try await achievedX(targetX: 4)

        XCTAssertGreaterThan(far, near)
        XCTAssertEqual(near, 0.05, accuracy: 0.01)
        XCTAssertEqual(far, 0.2, accuracy: 0.01)
    }

    /// Napęd kinematyczny z NaN ma być odrzucony razem z transakcją, a świat idzie dalej: następny `advance` robi krok bez
    /// problemu (wcześniej błąd wychodził dopiero w kroku i każdy kolejny `advance` odrzucał krok).
    func testNonFiniteKinematicDriveRejectsTheTransactionAndTheWorldKeepsStepping() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-20,-20], max: [20,20])))
        let id = ObjectID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.rigidBody(RigidBodyDescriptor(id: id, vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], motionRole: .kinematic,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)))))
        let first = await world.advance(by: 1.0 / 60)
        XCTAssertEqual(first.stepIndex, 1)
        let token = world.submit(WorldTransaction().setKinematicDrive(id, drive: .velocity(linear: [.nan, 0], angular: 0)))
        let rejecting = await world.advance(by: 1.0 / 60)
        XCTAssertTrue(rejecting.events.contains { event in
            if case .transactionRejected(let rejected, _) = event { return rejected == token }
            return false
        }, "transakcja z NaN w napędzie jest odrzucona")
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        let next = await world.advance(by: 1.0 / 60)
        XCTAssertEqual(next.stepIndex, rejecting.stepIndex + 1, "świat nie stoi po odrzuconej transakcji")
        XCTAssertGreaterThan(rejecting.stepIndex, first.stepIndex)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
    }
}
