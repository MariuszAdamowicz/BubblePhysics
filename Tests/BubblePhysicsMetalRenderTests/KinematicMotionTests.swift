import BubblePhysics
import BubblePhysicsMetalRender
import Metal
import XCTest
import simd

/// P-B-16, P-B-18, P-B-19 (G6-AC1..AC3): rola `kinematic` w publicznym `BubbleWorld`.
@MainActor
final class KinematicMotionTests: XCTestCase {
    private typealias B = SceneBuilders
    private let trackTolerance: Float = 1e-4

    private func state(_ frame: WorldFrame, _ id: UInt64) throws -> ObjectState {
        try XCTUnwrap(frame.objects[ObjectID(rawValue: id)], "brak obiektu \(id)")
    }

    // P-B-16: dwadzieścia baniek na drodze kinematycznej bryły; kontakt nie zmienia jej toru.
    func testKinematicBoxPushesTwentyBubblesAndStaysOnItsTrack() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device, region: WorldRectangle(min: [0, 0], max: [800, 300]))
        var transaction = try B.baseTransaction()
        transaction = transaction.add(try B.box(1000, at: [20, 104], half: [8, 40], role: .kinematic))
        transaction = transaction.setKinematicDrive(ObjectID(rawValue: 1000), drive: .velocity(linear: [12, 0], angular: 0))
        for index in 0..<20 {
            let position = WorldPoint(50 + Float(index % 4) * 12, 80 + Float(index / 4) * 12)
            transaction = transaction.add(try B.bubble(UInt64(index + 1), at: position, radius: 5))
        }
        world.submit(transaction)
        var worstDeviation: Float = 0
        let result = await B.advance(world, steps: 240) { _, frame in
            guard let box = frame.objects[ObjectID(rawValue: 1000)] else { return }
            let expected = WorldPoint(20 + 12 * Float(frame.simulationTime), 104)
            worstDeviation = max(worstDeviation, simd_distance(box.position, expected))
        }
        XCTAssertLessThanOrEqual(worstDeviation, trackTolerance, "odchyłka kinematycznej bryły od toru zadanego")
        let box = try state(result.frame, 1000)
        XCTAssertEqual(box.position.x, 20 + 12 * Float(result.frame.simulationTime), accuracy: trackTolerance)
        let bubbles = (1...20).compactMap { result.frame.objects[ObjectID(rawValue: UInt64($0))] }
        XCTAssertEqual(bubbles.count, 20)
        let meanX: Float = bubbles.map { $0.position.x }.reduce(0, +) / 20
        let meanShift = meanX - 68
        XCTAssertGreaterThan(meanShift, 10, "bańki mają zostać zepchnięte przez bryłę")
        XCTAssertTrue(bubbles.allSatisfy { $0.position.x > box.bounds.max.x - 1 }, "żadna bańka nie może przejść przez bryłę")
    }

    func testKinematicTargetDriveReachesPoseInOneStep() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: [50, 100], half: [10, 10], role: .kinematic))
            .setKinematicDrive(ObjectID(rawValue: 1), drive: .target(position: [80, 120], rotation: 0.5)))
        let result = await B.advance(world, steps: 1)
        let box = try state(result.frame, 1)
        XCTAssertEqual(box.position.x, 80, accuracy: trackTolerance)
        XCTAssertEqual(box.position.y, 120, accuracy: trackTolerance)
        XCTAssertEqual(box.rotation, 0.5, accuracy: trackTolerance)
        let later = await B.advance(world, steps: 5)
        XCTAssertEqual(try state(later.frame, 1).position.x, 80, accuracy: trackTolerance, "po osiągnięciu celu bryła stoi")
    }

    func testKinematicPathDriveFollowsPathAtDeclaredSpeed() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: [50, 100], half: [10, 10], role: .kinematic))
            .setKinematicDrive(ObjectID(rawValue: 1), drive: .path(PathDrive(points: [[250, 100]], speed: 30))))
        let result = await B.advance(world, steps: 60)
        let box = try state(result.frame, 1)
        XCTAssertEqual(box.position.x, 50 + 30 * Float(result.frame.simulationTime), accuracy: trackTolerance)
        XCTAssertEqual(box.position.y, 100, accuracy: trackTolerance)
    }

    // P-B-18: spoczywająca bryła dynamiczna jedzie z poziomą platformą kinematyczną.
    func testDynamicBoxRidesHorizontalKinematicPlatformAtPlatformSpeed() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device, gravity: [0, -500])
        world.submit(try B.baseTransaction(friction: 1)
            .add(B.box(1, at: [150, 50], half: [120, 4], role: .kinematic))
            .setKinematicDrive(ObjectID(rawValue: 1), drive: .velocity(linear: [10, 0], angular: 0))
            .add(B.box(2, at: [150, 59.5], half: [5, 5], role: .dynamic)))
        var samples: [Float] = []
        let result = await B.advance(world, steps: 180) { index, frame in
            if index >= 120, let rider = frame.objects[ObjectID(rawValue: 2)] { samples.append(rider.velocity.x) }
        }
        let mean = samples.reduce(0, +) / Float(max(samples.count, 1))
        XCTAssertEqual(mean, 10, accuracy: 0.5, "średnia prędkość pozioma bryły w granicach 5% prędkości platformy")
        XCTAssertGreaterThan(try state(result.frame, 2).position.y, 55, "bryła ma leżeć na platformie")
    }

    // P-B-19: kinematyczna nie koliduje ze statyczną ani z inną kinematyczną.
    func testKinematicBoxesPassThroughStaticAndOtherKinematicBodies() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(1, at: [50, 100], half: [10, 10], role: .kinematic))
            .setKinematicDrive(ObjectID(rawValue: 1), drive: .velocity(linear: [40, 0], angular: 0))
            .add(B.box(2, at: [100, 100], half: [5, 60], role: .static))
            .add(B.box(3, at: [200, 100], half: [10, 10], role: .kinematic))
            .setKinematicDrive(ObjectID(rawValue: 3), drive: .velocity(linear: [-40, 0], angular: 0)))
        let result = await B.advance(world, steps: 150)
        let time = Float(result.frame.simulationTime)
        XCTAssertEqual(try state(result.frame, 1).position.x, 50 + 40 * time, accuracy: trackTolerance)
        XCTAssertEqual(try state(result.frame, 3).position.x, 200 - 40 * time, accuracy: trackTolerance)
        XCTAssertEqual(try state(result.frame, 2).position, [100, 100])
    }

    // P-B-19: pathDriven wobec kinematycznej zachowuje się jak dynamiczna: zablokowana nieruchomą ścianą kinematyczną.
    func testPathDrivenBodyIsBlockedByStationaryKinematicBody() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [200, 100], half: [10, 40], role: .kinematic))
            .add(B.box(1, at: [100, 100], half: [10, 10], role: .dynamic, interest: .driveBlocked))
            .setPathDrive(ObjectID(rawValue: 1), drive: PathDrive(points: [[300, 100]], speed: 20)))
        var events: [WorldEvent] = []
        let result = await B.advance(world, steps: 360) { _, frame in events += frame.events }
        let box = try state(result.frame, 1)
        XCTAssertLessThanOrEqual(box.bounds.max.x, 190.5, "pathDriven nie może przejść przez kinematyczną")
        XCTAssertTrue(events.contains { if case .driveBlocked(let id, let by, _) = $0 { return id.rawValue == 1 && by.rawValue == 2 }; return false },
            "blokada pathDriven przez kinematyczną musi dać driveBlocked")
        let feedback = try XCTUnwrap(result.frame.driveFeedback.first { $0.objectID.rawValue == 1 })
        XCTAssertTrue(feedback.isStopped)
        XCTAssertEqual(feedback.blockingContact?.objectID.rawValue, 2)
    }

    // Kinematyczna może zepchnąć pathDriven; tor kinematycznej pozostaje dokładny.
    func testMovingKinematicBodyPushesPathDrivenBackWithoutLeavingItsTrack() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try B.makeWorld(device: device)
        world.submit(try B.baseTransaction()
            .add(B.box(2, at: [350, 100], half: [10, 40], role: .kinematic))
            .setKinematicDrive(ObjectID(rawValue: 2), drive: .velocity(linear: [-30, 0], angular: 0))
            .add(B.box(1, at: [100, 100], half: [10, 10], role: .dynamic))
            .setPathDrive(ObjectID(rawValue: 1), drive: PathDrive(points: [[400, 100]], speed: 20)))
        var overlap: Float = 0
        var deviation: Float = 0
        var furthest: Float = 0
        let result = await B.advance(world, steps: 360) { _, frame in
            guard let pushed = frame.objects[ObjectID(rawValue: 1)], let wall = frame.objects[ObjectID(rawValue: 2)] else { return }
            furthest = max(furthest, pushed.position.x)
            overlap = max(overlap, pushed.bounds.max.x - wall.bounds.min.x)
            deviation = max(deviation, abs(wall.position.x - (350 - 30 * Float(frame.simulationTime))))
        }
        XCTAssertLessThanOrEqual(deviation, trackTolerance)
        XCTAssertLessThanOrEqual(overlap, 0.5, "pathDriven ma zostać zepchnięta, nie przeniknąć")
        XCTAssertGreaterThan(furthest, 150, "pathDriven najpierw dojeżdża do ściany")
        XCTAssertLessThan(try state(result.frame, 1).position.x, furthest - 20, "kinematyczna ściana cofnęła pathDriven")
    }
}
