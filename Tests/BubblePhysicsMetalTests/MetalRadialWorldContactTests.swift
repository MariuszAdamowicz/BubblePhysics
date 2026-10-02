import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialWorldContactTests: XCTestCase {
    func testGPUPairContactsMatchCPUReference() async throws {
        let world = try makeWorld(centers: [.zero, Vector2(x: 15, y: 0)], radii: [10, 10])
        let expected = RadialBubbleContacts.generate(first: world.bubbles[0], second: world.bubbles[1]).count
        let frame = try await run(world)
        XCTAssertEqual(frame.pairContactCount, expected)
    }

    func testGPUWorldPreservesPairLinearMomentum() async throws {
        let base = try makeWorld(centers: [.zero, Vector2(x: 15, y: 2)], radii: [10, 10])
        var bubbles = base.bubbles
        bubbles[0].body.linearVelocity = Vector2(x: 3, y: 1)
        bubbles[1].body.linearVelocity = Vector2(x: -1, y: -2)
        let world = try RadialWorldState(bubbles: bubbles)
        let before = momentum(world)
        let (_, simulation) = try await runWithSimulation(world)
        let after = momentum(simulation.world)
        XCTAssertEqual(after.x, before.x, accuracy: 1e-3)
        XCTAssertEqual(after.y, before.y, accuracy: 1e-3)
    }

    func testContactOrderDoesNotChangeWorldResult() async throws {
        let a = try makeWorld(centers: [.zero, Vector2(x: 15, y: 0), Vector2(x: 7, y: 12)], radii: [10, 10, 10])
        let b = try RadialWorldState(bubbles: a.bubbles.reversed())
        let (_, first) = try await runWithSimulation(a)
        let (_, second) = try await runWithSimulation(b)
        let firstByID = Dictionary(uniqueKeysWithValues: first.world.bubbles.map { ($0.id, $0.body.linearVelocity) })
        for bubble in second.world.bubbles {
            XCTAssertEqual(bubble.body.linearVelocity.x, firstByID[bubble.id]!.x, accuracy: 1e-4)
            XCTAssertEqual(bubble.body.linearVelocity.y, firstByID[bubble.id]!.y, accuracy: 1e-4)
        }
    }

    func testSweptTriangleCannotTunnelThroughBubble() throws {
        let world = try makeWorld(centers: [.zero], radii: [10])
        let fast = polygon(position: Vector2(x: -30, y: 0), velocity: Vector2(x: 1_000, y: 0))
        XCTAssertGreaterThan(MetalRadialWorldSimulation.substepCount(for: world, polygons: [fast], deltaTime: 1 / 30), 1)
    }

    func testExtremeSizeRatioProducesCandidateAndContact() async throws {
        let world = try makeWorld(centers: [.zero, Vector2(x: 199, y: 0)], radii: [200, 2])
        let frame = try await run(world)
        XCTAssertEqual(frame.candidatePairCount, 1)
        XCTAssertGreaterThan(frame.pairContactCount, 0)
    }

    private func run(_ world: RadialWorldState) async throws -> MetalRadialWorldFrameResources {
        try await runWithSimulation(world).0
    }

    private func runWithSimulation(
        _ world: RadialWorldState
    ) async throws -> (MetalRadialWorldFrameResources, MetalRadialWorldSimulation) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let simulation = try MetalRadialWorldSimulation(device: device, world: world)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try simulation.encodeStep(
            bounds: AABB(minimum: Vector2(x: -1_000, y: -1_000), maximum: Vector2(x: 1_000, y: 1_000)),
            polygons: [], deltaTime: 1 / 120, commandBuffer: command
        )
        command.commit(); await command.completed()
        try simulation.complete(frame: frame, commandBuffer: command)
        return (frame, simulation)
    }

    private func makeWorld(centers: [Vector2], radii: [Float]) throws -> RadialWorldState {
        try RadialWorldState(bubbles: zip(centers, radii).enumerated().map { index, values in
            var bubble = RadialBubbleState.collapsed(
                id: BubbleID(rawValue: index + 1), center: values.0, targetRadius: values.1,
                maxSegmentLength: max(1, values.1), mass: 1
            )
            bubble.birthProgress = 1
            bubble.dynamics.bodyLinearDrag = 0
            for sensor in bubble.sensors.indices {
                bubble.sensors[sensor].length = values.1
                bubble.sensors[sensor].targetLength = values.1
            }
            return bubble
        })
    }

    private func momentum(_ world: RadialWorldState) -> Vector2 {
        world.bubbles.reduce(.zero) { $0 + $1.body.linearVelocity * $1.body.mass }
    }

    private func polygon(position: Vector2, velocity: Vector2) -> SimulationPolygonSnapshot {
        SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 1), mode: .kinematic,
            worldVertices: [position + Vector2(x: -2, y: -2), position + Vector2(x: 2, y: 0), position + Vector2(x: -2, y: 2)],
            position: position, linearVelocity: velocity, angularVelocity: 0
        )
    }
}
