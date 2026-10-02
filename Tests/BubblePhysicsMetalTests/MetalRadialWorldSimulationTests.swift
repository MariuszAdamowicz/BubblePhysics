import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialWorldSimulationTests: XCTestCase {
    func testPackedWorldPreservesBodyAndSensorRanges() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let world = try makeWorld(counts: [8, 13, 21])
        let simulation = try MetalRadialWorldSimulation(device: device, world: world)

        XCTAssertEqual(simulation.world, world)
        XCTAssertEqual(simulation.resources.ranges, world.ranges)
        XCTAssertEqual(simulation.resources.bubbleCount, 3)
        XCTAssertEqual(simulation.resources.sensorCount, 42)
    }

    func testFreeGPUWorldMatchesCPUForMultipleBubbles() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let initial = try makeWorld(counts: [8, 13])
        var expected = initial.bubbles
        for index in expected.indices {
            RadialBubbleIntegrator.step(
                state: &expected[index], load: .zero(sensorCount: expected[index].sensors.count),
                deltaTime: 1 / 120
            )
        }
        let simulation = try MetalRadialWorldSimulation(device: device, world: initial)
        let command = try XCTUnwrap(queue.makeCommandBuffer())

        let frame = try simulation.encodeFreeStep(deltaTime: 1 / 120, commandBuffer: command)
        command.commit()
        await command.completed()
        try simulation.complete(frame: frame, commandBuffer: command)

        for (actual, reference) in zip(simulation.world.bubbles, expected) {
            XCTAssertEqual(actual.body.center.x, reference.body.center.x, accuracy: 1e-4)
            XCTAssertEqual(actual.birthProgress, reference.birthProgress, accuracy: 1e-4)
            XCTAssertEqual(actual.sensors[0].length, reference.sensors[0].length, accuracy: 1e-4)
        }
    }

    func testFrameBoundaryRemeshAtomicallyReplacesRanges() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let initial = try makeWorld(counts: [8, 8])
        let simulation = try MetalRadialWorldSimulation(device: device, world: initial)
        let decisions = [RadialRemeshDecision(bubbleID: initial.bubbles[0].id, sensorCount: 21, frameIndex: 15)]

        try simulation.applyRemesh(decisions)

        XCTAssertEqual(simulation.world.bubbles[0].sensors.count, 21)
        XCTAssertEqual(simulation.resources.ranges[1].sensorStart, 21)
    }

    func testFailedWorldReallocationDoesNotPublishPartialLayout() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let initial = try makeWorld(counts: [8, 8])
        let allocator = FailingAllocator()
        let simulation = try MetalRadialWorldSimulation(device: device, world: initial, allocator: allocator)
        allocator.failNextAllocation = true

        XCTAssertThrowsError(try simulation.applyRemesh([
            RadialRemeshDecision(bubbleID: initial.bubbles[0].id, sensorCount: 21, frameIndex: 15)
        ]))
        XCTAssertEqual(simulation.world, initial)
        XCTAssertEqual(simulation.resources.ranges, initial.ranges)
    }

    private func makeWorld(counts: [Int]) throws -> RadialWorldState {
        try RadialWorldState(bubbles: counts.enumerated().map { index, count in
            var bubble = RadialBubbleState.collapsed(
                id: BubbleID(rawValue: index + 1), center: Vector2(x: Float(index * 20), y: 0),
                targetRadius: 10 + Float(index), maxSegmentLength: 5, mass: 1
            )
            bubble = RadialSensorRemesher.resample(bubble, to: count)
            bubble.body.linearVelocity = Vector2(x: Float(index + 1), y: -1)
            return bubble
        })
    }
}

private final class FailingAllocator: MetalBufferAllocator, @unchecked Sendable {
    var failNextAllocation = false

    func makeBuffer(device: MTLDevice, length: Int, options: MTLResourceOptions) -> MTLBuffer? {
        if failNextAllocation { failNextAllocation = false; return nil }
        return device.makeBuffer(length: length, options: options)
    }
}
