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

    /// Wynik scalenia jedzie z polityką z `BubbleResult`: przy `maximumSpeed` 3 przesuwa się w kroku 1/60 o ≈ 0.05,
    /// a nie o 0.2 jak przy `.standard` z prędkością 12.
    func testMergedBubbleDrivesWithDrivePolicyFromBubbleResult() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-20,-20], max: [20,20])))
        let material = PhysicsMaterialID(rawValue: 1), style = RenderMaterialID(rawValue: 1)
        let merged = ObjectID(rawValue: 3)
        let policy = try BubbleDrivePolicy(maximumSpeed: 3)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(material, material: PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(style, material: try RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: ObjectID(rawValue: 1), position: [-1, 0], targetRadius: 0.5,
                physicsMaterialID: material, renderMaterialID: style)))
            .add(.bubble(BubbleDescriptor(id: ObjectID(rawValue: 2), position: [1, 0], targetRadius: 0.5,
                physicsMaterialID: material, renderMaterialID: style)))
            .mergeBubbles([ObjectID(rawValue: 1), ObjectID(rawValue: 2)], result: BubbleResult(id: merged,
                physicsMaterialID: material, renderMaterialID: style, drivePolicy: policy))
            .beginPlayerDrive(merged, target: [10, 0]))
        let frame = await world.advance(by: 1.0 / 60)
        XCTAssertEqual(frame.transactionReceipts.count, 1)
        let feedback = try XCTUnwrap(frame.driveFeedback.first)
        XCTAssertEqual(feedback.objectID, merged)
        XCTAssertEqual(feedback.achievedPoint.x, 0.05, accuracy: 0.01)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
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

    /// Skończona, ale ogromna wartość napędu (target / velocity) przepełniała `Float` dopiero przy dzieleniu przez `dt`
    /// w kroku: transakcja nie była odrzucona ani zastosowana i świat stał. Ma być odrzucona w stagerze.
    func testHugeFiniteKinematicDriveRejectsTheTransactionAndTheWorldKeepsStepping() async throws {
        let drives: [(String, KinematicDrive)] = [
            ("target.position", .target(position: [3e38, 0], rotation: 0)),
            ("target.rotation", .target(position: .zero, rotation: 3e38)),
            ("velocity.linear", .velocity(linear: [0, -3e38], angular: 0)),
            ("velocity.angular", .velocity(linear: .zero, angular: 3e38)),
        ]
        for (name, drive) in drives {
            let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
                WorldRectangle(min: [-20,-20], max: [20,20])))
            let id = ObjectID(rawValue: 1)
            world.submit(try WorldTransaction()
                .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .rigid))
                .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
                .add(.rigidBody(RigidBodyDescriptor(id: id, vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], motionRole: .kinematic,
                    physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)))))
            let first = await world.advance(by: 1.0 / 60)
            XCTAssertEqual(first.stepIndex, 1, name)
            let token = world.submit(WorldTransaction().setKinematicDrive(id, drive: drive))
            let rejecting = await world.advance(by: 1.0 / 60)
            XCTAssertTrue(rejecting.events.contains { event in
                if case .transactionRejected(let rejected, _) = event { return rejected == token }
                return false
            }, "\(name): transakcja z ogromną wartością jest odrzucona")
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, name)
            let next = await world.advance(by: 1.0 / 60)
            XCTAssertEqual(next.stepIndex, rejecting.stepIndex + 1, "\(name): świat nie stoi po odrzuconej transakcji")
            XCTAssertNil(world.diagnostics.lastAdvanceIssue, name)
        }
    }

    /// Wartości dużo większe niż realny świat, ale poniżej limitu, nadal przechodzą (limit nie jest zbyt ciasny).
    func testLargeButReasonableKinematicTargetIsAccepted() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-20,-20], max: [20,20])))
        let id = ObjectID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.rigidBody(RigidBodyDescriptor(id: id, vertices: [[0, 0], [2, 0], [2, 2], [0, 2]], motionRole: .kinematic,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1)))))
        _ = await world.advance(by: 1.0 / 60)
        let token = world.submit(WorldTransaction().setKinematicDrive(id, drive: .velocity(linear: [1000, 0], angular: 1)))
        let frame = await world.advance(by: 1.0 / 60)
        XCTAssertFalse(frame.events.contains { event in
            if case .transactionRejected(let rejected, _) = event { return rejected == token }
            return false
        })
    }

    // MARK: gumka siłowa (v2.3.0, P-B-5, P-B-7)

    private func assertOutOfRange(_ name: String, file: StaticString = #filePath, line: UInt = #line,
                                  _ build: () throws -> BubbleDrivePolicy) {
        XCTAssertThrowsError(try build(), name, file: file, line: line) { error in
            XCTAssertEqual(error as? ModelValidationError, .valueOutOfRange(name), file: file, line: line)
        }
    }

    /// P-B-5 (G1-AC5): `valueOutOfRange` z nazwą pola także dla ∞, 0 i wartości ujemnych (nie `nonFiniteValue` / `nonPositiveValue`).
    func testBandPolicyRejectsOutOfRangeFieldsWithTheFieldName() throws {
        for value: Float in [0, -1, .infinity, .nan] {
            assertOutOfRange("drive.bandStiffness") { try BubbleDrivePolicy(bandStiffness: value) }
        }
        for value: Float in [-0.5, .infinity, .nan] {
            assertOutOfRange("drive.bandDamping") { try BubbleDrivePolicy(bandStiffness: 10, bandDamping: value) }
        }
        for value: Float in [0, -1, .infinity, .nan] {
            assertOutOfRange("drive.maximumForce") { try BubbleDrivePolicy(bandStiffness: 10, maximumForce: value) }
        }
    }

    /// P-B-5, CD-D-14: pola gumki bez `bandStiffness` są sprzeczną konfiguracją.
    func testBandDampingOrMaximumForceWithoutStiffnessIsRejected() throws {
        assertOutOfRange("drive.bandDamping") { try BubbleDrivePolicy(bandDamping: 1) }
        assertOutOfRange("drive.maximumForce") { try BubbleDrivePolicy(maximumForce: 100) }
        let band = try BubbleDrivePolicy(bandStiffness: 10, bandDamping: 2, maximumForce: 500)
        XCTAssertEqual(band.bandStiffness, 10)
        XCTAssertEqual(band.bandDamping, 2)
        XCTAssertEqual(band.maximumForce, 500)
        let defaults = try BubbleDrivePolicy(bandStiffness: 10)
        XCTAssertEqual(defaults.bandDamping, 0)
        XCTAssertNil(defaults.maximumForce)
        XCTAssertNil(BubbleDrivePolicy.standard.bandStiffness)
    }

    /// Cel o ogromnej, ale skończonej składowej: w trybie gumki siła K·(cel − położenie) przepełniłaby `Float` (P-B-7),
    /// w trybie prędkościowym cel jest tylko kierunkiem i zostaje przyjęty (bez zmian względem v2.2.0).
    private static func wasRejected(_ frame: WorldFrame, _ token: TransactionToken) -> Bool {
        frame.events.contains { event in
            if case .transactionRejected(let rejected, _) = event { return rejected == token }
            return false
        }
    }

    private func isHugeTargetRejected(policy: BubbleDrivePolicy, update: Bool) async throws -> Bool {
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-20,-20], max: [20,20])))
        let id = ObjectID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1), drivePolicy: policy))))
        let huge = WorldPoint(1e38, 0)
        let token: TransactionToken
        if update {
            world.submit(WorldTransaction().beginPlayerDrive(id, target: [1, 0]))
            _ = await world.advance(by: 1.0 / 60)
            token = world.submit(WorldTransaction().updatePlayerDrive(id, target: huge))
        } else {
            token = world.submit(WorldTransaction().beginPlayerDrive(id, target: huge))
        }
        let frame = await world.advance(by: 1.0 / 60)
        XCTAssertNil(world.diagnostics.lastAdvanceIssue)
        return Self.wasRejected(frame, token)
    }

    func testHugeDriveTargetIsRejectedInBandModeAndAcceptedInVelocityMode() async throws {
        let band = try BubbleDrivePolicy(bandStiffness: 10)
        let velocity = try BubbleDrivePolicy()
        let beginVelocity = try await isHugeTargetRejected(policy: velocity, update: false)
        let updateVelocity = try await isHugeTargetRejected(policy: velocity, update: true)
        let beginBand = try await isHugeTargetRejected(policy: band, update: false)
        let updateBand = try await isHugeTargetRejected(policy: band, update: true)
        XCTAssertTrue(beginBand, "beginPlayerDrive w trybie gumki")
        XCTAssertTrue(updateBand, "updatePlayerDrive w trybie gumki")
        XCTAssertFalse(beginVelocity, "beginPlayerDrive w trybie prędkościowym")
        XCTAssertFalse(updateVelocity, "updatePlayerDrive w trybie prędkościowym")
    }

    /// Rozsądny cel w trybie gumki nie jest odrzucany (limit nie jest zbyt ciasny).
    func testReasonableDriveTargetIsAcceptedInBandMode() async throws {
        let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
            WorldRectangle(min: [-20,-20], max: [20,20])))
        let id = ObjectID(rawValue: 1)
        world.submit(try WorldTransaction()
            .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .bubble))
            .updateRenderMaterial(.init(rawValue: 1), material: try RenderMaterial())
            .add(.bubble(BubbleDescriptor(id: id, position: .zero, targetRadius: 0.5,
                physicsMaterialID: .init(rawValue: 1), renderMaterialID: .init(rawValue: 1),
                drivePolicy: BubbleDrivePolicy(bandStiffness: 10)))))
        let token = world.submit(WorldTransaction().beginPlayerDrive(id, target: [900_000, -900_000]))
        let frame = await world.advance(by: 1.0 / 60)
        XCTAssertFalse(frame.events.contains { event in
            if case .transactionRejected(let rejected, _) = event { return rejected == token }
            return false
        })
    }
}
