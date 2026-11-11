import XCTest
import Metal
import BubblePhysicsReference
import BubblePhysicsNativeMetal
@testable import BubblePhysicsNativeMetalDiagnostics

/// Adapter diagnostyczny: `ReferenceWorld` ↔ neutralne wejście i wynik solvera.
@MainActor
final class ReferenceSolverInputAdapterTests: XCTestCase {
    private func world() throws -> ReferenceWorld {
        var world = ReferenceWorld(configuration: .init(timeStep: 0.25, linearDamping: 0, angularDamping: 0),
                                   broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 5), center: .init(x: 1, y: 2),
            velocity: .init(x: 2, y: -1), mass: 4, targetRadius: 1.5, stiffness: 0.5, rotation: 0.3, angularVelocity: 0.1))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .init(x: 6, y: 0), mass: 1, targetRadius: 1))
        world.addSegment(.staticSegment(id: .init(rawValue: 9), a: .init(x: -3, y: 0), b: .init(x: 3, y: 0),
            ownerID: 77, collisionMode: .oneSided(allowedSide: -1)))
        world.addSegment(.kinematicSegment(id: .init(rawValue: 4), previousA: .init(x: 0, y: 0), previousB: .init(x: 0, y: 1),
            currentA: .init(x: 1, y: 0), currentB: .init(x: 1, y: 1), timeStep: 0.25))
        return world
    }

    func testInputCarriesEveryBubbleSegmentAndConfigurationField() throws {
        let world = try world()
        let input = ReferenceSolverInputAdapter.input(from: world)
        XCTAssertEqual(input.bubbles.map(\.id.rawValue), [2, 5])
        let bubble = try XCTUnwrap(input.bubbles.last)
        XCTAssertEqual(bubble.center, [1, 2]); XCTAssertEqual(bubble.velocity, [2, -1])
        XCTAssertEqual(bubble.mass, 4); XCTAssertEqual(bubble.inverseMass, 0.25)
        XCTAssertEqual(bubble.targetRadius, 1.5); XCTAssertEqual(bubble.stiffness, 0.5)
        XCTAssertEqual(bubble.rotation, 0.3); XCTAssertEqual(bubble.angularVelocity, 0.1)
        XCTAssertEqual(input.segments.map(\.id), [4, 9])
        XCTAssertTrue(input.segments[0].isKinematic)
        XCTAssertEqual(input.segments[0].linearVelocity.x, 4, accuracy: 1e-5)
        XCTAssertEqual(input.segments[1].allowedSide, -1)
        XCTAssertEqual(input.segments[1].ownerID, 77)
        XCTAssertFalse(input.segments[1].isKinematic)
        XCTAssertEqual(input.configuration.timeStep, 0.25)
        XCTAssertEqual(input.configuration.linearDamping, 0)
        XCTAssertEqual(input.configuration.contactStiffness, world.configuration.contactStiffness)
        XCTAssertEqual(input.configuration.maxContourSegmentLength, world.configuration.maxContourSegmentLength)
    }

    func testSolverFrameTranslatesBackToReferenceTypes() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        let world = try world()
        let neutral = try await solver.executeFrame(input: ReferenceSolverInputAdapter.input(from: world), scenarioStep: 1)
        let frame = ReferenceSolverInputAdapter.worldFrame(from: neutral)
        XCTAssertEqual(frame.bubbles.map(\.id.rawValue), neutral.bubbles.map(\.id.rawValue))
        XCTAssertEqual(frame.bubbles[1].center.x, neutral.bubbles[1].center.x)
        XCTAssertEqual(frame.contacts.count, neutral.contacts.count)
        XCTAssertEqual(frame.report.generatedContactCount, neutral.report.generatedContactCount)
        XCTAssertEqual(frame.contours.count, neutral.contours.count)
        XCTAssertEqual(frame.telemetry, neutral.telemetry)
        XCTAssertTrue(frame.isComplete)
        // Kanał świata zwraca dokładnie to samo co rdzeń z wejściem neutralnym.
        let viaWorld = try await NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
            .executeFrame(world: world, scenarioStep: 1)
        XCTAssertEqual(viaWorld.bubbles, frame.bubbles)
    }
}
