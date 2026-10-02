import Metal
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialWorldSubstepTests: XCTestCase {
    func testBatchedFreeSubstepsMatchSequentialCommands() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let world = try RadialWorldState(bubbles: [bubble(center: Vector2(x: 50, y: 50))])
        let batched = try MetalRadialWorldSimulation(device: device, world: world)
        let sequential = try MetalRadialWorldSimulation(device: device, world: world)

        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try batched.encodeSteps(
            bounds: bounds,
            steps: Array(repeating: .init(polygons: [], deltaTime: 1 / 120), count: 4),
            commandBuffer: command
        )
        command.commit()
        await command.completed()
        try batched.complete(frame: frame, commandBuffer: command)

        for _ in 0..<4 {
            let sequentialCommand = try XCTUnwrap(queue.makeCommandBuffer())
            let sequentialFrame = try sequential.encodeStep(
                bounds: bounds, polygons: [], deltaTime: 1 / 120,
                commandBuffer: sequentialCommand
            )
            sequentialCommand.commit()
            await sequentialCommand.completed()
            try sequential.complete(frame: sequentialFrame, commandBuffer: sequentialCommand)
        }

        XCTAssertEqual(batched.world.bubbles[0].birthProgress, sequential.world.bubbles[0].birthProgress, accuracy: 1e-5)
        XCTAssertEqual(batched.world.bubbles[0].sensors[0].length, sequential.world.bubbles[0].sensors[0].length, accuracy: 1e-4)
    }

    func testInterpolatedKinematicSubstepsPushBubbleAndRemainFinite() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let initial = try RadialWorldState(bubbles: [bubble(center: Vector2(x: 50, y: 50))])
        let simulation = try MetalRadialWorldSimulation(device: device, world: initial)
        let xs: [Float] = [25, 40, 55, 70]
        let steps = xs.map { x in
            MetalRadialWorldStep(polygons: [triangle(centerX: x)], deltaTime: 1 / 120)
        }
        let command = try XCTUnwrap(queue.makeCommandBuffer())

        let frame = try simulation.encodeSteps(bounds: bounds, steps: steps, commandBuffer: command)
        command.commit()
        await command.completed()
        try simulation.complete(frame: frame, commandBuffer: command)

        let metrics = RadialWorldFrameMetrics(world: simulation.world, frame: frame)
        XCTAssertFalse(metrics.didEncounterNonFinite)
        XCTAssertGreaterThan(simulation.world.bubbles[0].body.linearVelocity.x, 0)
    }

    private let bounds = AABB(minimum: .zero, maximum: Vector2(x: 100, y: 100))

    private func bubble(center: Vector2) -> RadialBubbleState {
        var result = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1), center: center,
            targetRadius: 12, maxSegmentLength: 5, mass: 8
        )
        result.birthProgress = 1
        for index in result.sensors.indices {
            result.sensors[index].length = 12
            result.sensors[index].targetLength = 12
        }
        return result
    }

    private func triangle(centerX: Float) -> SimulationPolygonSnapshot {
        SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 1), mode: .kinematic,
            worldVertices: [
                Vector2(x: centerX - 5, y: 44), Vector2(x: centerX + 5, y: 50),
                Vector2(x: centerX - 5, y: 56)
            ],
            position: Vector2(x: centerX, y: 50),
            linearVelocity: Vector2(x: 1_800, y: 0), angularVelocity: 0
        )
    }
}
