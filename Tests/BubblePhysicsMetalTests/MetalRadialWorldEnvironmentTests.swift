import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialWorldEnvironmentTests: XCTestCase {
    private let bounds = AABB(minimum: .zero, maximum: Vector2(x: 100, y: 100))

    func testGPUDetectsEdgeCrossingBetweenSensors() async throws {
        var bubble = makeBubble(id: 1, center: Vector2(x: 50, y: 50), radius: 10)
        bubble.body.angle = .pi / 8
        let bar = polygon([
            Vector2(x: 35, y: 49), Vector2(x: 65, y: 49),
            Vector2(x: 65, y: 51), Vector2(x: 35, y: 51)
        ])

        let frame = try await run(world: RadialWorldState(bubbles: [bubble]), polygons: [bar])

        XCTAssertGreaterThan(frame.contactCount, 0)
        XCTAssertGreaterThan(frame.maximumPenetration, 0)
    }

    func testGPUDetectsPolygonContainedByLargeBubble() async throws {
        let bubble = makeBubble(id: 1, center: Vector2(x: 50, y: 50), radius: 20)
        let triangle = polygon([
            Vector2(x: 48, y: 48), Vector2(x: 52, y: 48), Vector2(x: 50, y: 52)
        ])

        let frame = try await run(world: RadialWorldState(bubbles: [bubble]), polygons: [triangle])

        XCTAssertGreaterThanOrEqual(frame.contactCount, 3)
    }

    func testGPUEnvironmentContactsMatchCPUReference() async throws {
        let first = makeBubble(id: 1, center: Vector2(x: 5, y: 50), radius: 10)
        let second = makeBubble(id: 2, center: Vector2(x: 50, y: 50), radius: 12)
        let triangle = polygon([
            Vector2(x: 43, y: 43), Vector2(x: 58, y: 43), Vector2(x: 50, y: 60)
        ])
        let world = try RadialWorldState(bubbles: [first, second])
        let expected = world.bubbles.reduce(0) {
            $0 + RadialEnvironmentContacts.generate(bubble: $1, bounds: bounds, polygons: [triangle]).count
        }

        let frame = try await run(world: world, polygons: [triangle])

        XCTAssertEqual(frame.contactCount, expected)
        XCTAssertFalse(frame.overflow)
    }

    func testEnvironmentOverflowFailsExplicitly() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let world = try RadialWorldState(bubbles: [
            makeBubble(id: 1, center: Vector2(x: 2, y: 2), radius: 10)
        ])
        let simulation = try MetalRadialWorldSimulation(
            device: device, world: world, environmentContactCapacity: 1
        )
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try simulation.encodeStep(bounds: bounds, polygons: [], deltaTime: 1 / 120, commandBuffer: command)
        command.commit()
        await command.completed()

        XCTAssertThrowsError(try simulation.complete(frame: frame, commandBuffer: command))
        XCTAssertEqual(simulation.status, .failed)
    }

    private func run(
        world: RadialWorldState, polygons: [SimulationPolygonSnapshot]
    ) async throws -> MetalRadialWorldFrameResources {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let simulation = try MetalRadialWorldSimulation(device: device, world: world)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try simulation.encodeStep(
            bounds: bounds, polygons: polygons, deltaTime: 1 / 120, commandBuffer: command
        )
        command.commit()
        await command.completed()
        try simulation.complete(frame: frame, commandBuffer: command)
        return frame
    }

    private func makeBubble(id: Int, center: Vector2, radius: Float) -> RadialBubbleState {
        var bubble = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: id), center: center, targetRadius: radius,
            maxSegmentLength: radius, mass: 1
        )
        bubble.birthProgress = 1
        for index in bubble.sensors.indices {
            bubble.sensors[index].length = radius
            bubble.sensors[index].targetLength = radius
        }
        return bubble
    }

    private func polygon(_ vertices: [Vector2]) -> SimulationPolygonSnapshot {
        SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 1), mode: .kinematic,
            worldVertices: vertices, position: Vector2(x: 50, y: 50),
            linearVelocity: .zero, angularVelocity: 0
        )
    }
}
