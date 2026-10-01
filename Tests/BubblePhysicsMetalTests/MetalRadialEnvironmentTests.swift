import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialEnvironmentTests: XCTestCase {
    func testMetalWallContactsMatchCPUCountAndLoad() async throws {
        let state = bubble(center: Vector2(x: 4, y: 4))
        let bounds = AABB(minimum: .zero, maximum: Vector2(x: 100, y: 100))

        try await assertParity(state: state, bounds: bounds, polygons: [])
    }

    func testMetalKinematicPolygonContactsMatchCPUCountAndLoad() async throws {
        let state = bubble(center: Vector2(x: 50, y: 50))
        let bounds = AABB(minimum: .zero, maximum: Vector2(x: 100, y: 100))
        let polygon = SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 9), mode: .kinematic,
            worldVertices: [Vector2(x: 40, y: 40), Vector2(x: 60, y: 40), Vector2(x: 50, y: 65)],
            position: Vector2(x: 50, y: 50),
            linearVelocity: Vector2(x: 2, y: -1), angularVelocity: 0.5
        )

        try await assertParity(state: state, bounds: bounds, polygons: [polygon])
    }

    private func assertParity(
        state: RadialBubbleState,
        bounds: AABB,
        polygons: [SimulationPolygonSnapshot]
    ) async throws {
        let cpuContacts = RadialEnvironmentContacts.generate(bubble: state, bounds: bounds, polygons: polygons)
        let cpuLoad = RadialContactResponse.reduce(contacts: cpuContacts, for: state)
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let simulation = try MetalRadialSimulation(device: device, state: state)
        let command = try XCTUnwrap(queue.makeCommandBuffer())

        let frame = try simulation.encodeStep(
            bounds: bounds, polygons: polygons, deltaTime: 1 / 60, commandBuffer: command
        )
        command.commit()
        await command.completed()
        try simulation.complete(frame: frame, commandBuffer: command)

        XCTAssertEqual(frame.contactCount, cpuContacts.count)
        let gpuLoad = frame.reducedLoad()
        XCTAssertEqual(gpuLoad.force.x, cpuLoad.force.x, accuracy: 2e-3)
        XCTAssertEqual(gpuLoad.force.y, cpuLoad.force.y, accuracy: 2e-3)
        XCTAssertEqual(gpuLoad.torque, cpuLoad.torque, accuracy: 2e-3)
        for index in cpuLoad.sensorCompression.indices {
            XCTAssertEqual(gpuLoad.sensorCompression[index], cpuLoad.sensorCompression[index], accuracy: 2e-3)
            XCTAssertEqual(gpuLoad.sensorPressureDeltas[index], cpuLoad.sensorPressureDeltas[index], accuracy: 2e-3)
        }
    }

    private func bubble(center: Vector2) -> RadialBubbleState {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1), center: center, targetRadius: 10,
            maxSegmentLength: 10, mass: 1
        )
        state.birthProgress = 1
        state.material = SpringMaterial(quadraticStiffness: 10, quarticStiffness: 0, drag: 0)
        for index in state.sensors.indices {
            state.sensors[index].length = 10
            state.sensors[index].targetLength = 10
        }
        return state
    }
}
