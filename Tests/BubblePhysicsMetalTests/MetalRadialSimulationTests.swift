import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialSimulationTests: XCTestCase {
    private let dt: Float = 1 / 60

    func testMetalBirthMatchesCPUReferenceForTenSteps() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var cpu = makeState()
        let simulation = try MetalRadialSimulation(device: device, state: cpu)

        for _ in 0..<10 {
            let load = RadialBodyLoad.zero(sensorCount: cpu.sensors.count)
            RadialBubbleIntegrator.step(state: &cpu, load: load, deltaTime: dt)
            _ = try await step(simulation, queue: queue, load: load)
        }
        let gpu = simulation.state

        XCTAssertEqual(gpu.body.center.x, cpu.body.center.x, accuracy: 2e-3)
        XCTAssertEqual(gpu.body.center.y, cpu.body.center.y, accuracy: 2e-3)
        XCTAssertEqual(gpu.body.angle, cpu.body.angle, accuracy: 2e-3)
        XCTAssertEqual(gpu.birthProgress, cpu.birthProgress, accuracy: 2e-3)
        for index in cpu.sensors.indices {
            XCTAssertEqual(gpu.sensors[index].length, cpu.sensors[index].length, accuracy: 2e-3)
        }
    }

    func testMetalSymmetricPressureProducesNoTorque() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        var state = makeState(expanded: true)
        state.body.angle = 0.4
        let simulation = try MetalRadialSimulation(device: device, state: state)
        var load = RadialBodyLoad.zero(sensorCount: state.sensors.count)
        load.sensorPressureDeltas = Array(repeating: 20, count: state.sensors.count)

        for _ in 0..<30 { _ = try await step(simulation, queue: queue, load: load) }

        XCTAssertEqual(simulation.state.body.center, state.body.center)
        XCTAssertEqual(simulation.state.body.angle, state.body.angle, accuracy: 2e-3)
        XCTAssertEqual(simulation.state.body.angularVelocity, 0, accuracy: 2e-3)
    }

    func testMetalContactOrderDoesNotChangeReducedLoad() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let state = makeState(expanded: true)
        let contacts = [
            contact(id: 30, sensor: 0, point: Vector2(x: 10, y: 1), normal: Vector2(x: -1, y: 0), penetration: 0.7),
            contact(id: 10, sensor: 2, point: Vector2(x: -2, y: 9), normal: Vector2(x: 0, y: -1), penetration: 1.1),
            contact(id: 20, sensor: 5, point: Vector2(x: -7, y: -4), normal: Vector2(x: 0.6, y: 0.8), penetration: 0.4)
        ]
        let first = try MetalRadialSimulation(device: device, state: state)
        let second = try MetalRadialSimulation(device: device, state: state)

        let firstFrame = try await step(first, queue: queue, contacts: contacts)
        let secondFrame = try await step(second, queue: queue, contacts: contacts.reversed())

        assertLoad(firstFrame.reducedLoad(), equals: secondFrame.reducedLoad())
    }

    func testMetalExtremeCompressionStaysFiniteAndNonnegative() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let state = makeState(expanded: true)
        let simulation = try MetalRadialSimulation(device: device, state: state)
        var load = RadialBodyLoad.zero(sensorCount: state.sensors.count)
        load.sensorCompression[0] = 3
        load.sensorPressureDeltas[0] = 100_000

        for _ in 0..<600 { _ = try await step(simulation, queue: queue, load: load) }

        XCTAssertTrue(simulation.state.sensors.allSatisfy { $0.length.isFinite && $0.length >= 0 })
        XCTAssertTrue(simulation.state.body.center.x.isFinite)
        XCTAssertTrue(simulation.state.body.center.y.isFinite)
    }

    func testMetalBuffersSupportSensorCountAboveSixtyFour() async throws {
        XCTAssertEqual(MemoryLayout<MetalRadialBody>.stride, 64)
        XCTAssertEqual(MemoryLayout<MetalRadialSensor>.stride, 32)
        XCTAssertEqual(MemoryLayout<MetalRadialContact>.stride, 64)

        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let state = RadialSensorRemesher.resample(makeState(expanded: true), to: 257)
        let simulation = try MetalRadialSimulation(device: device, state: state)

        let frame = try await step(simulation, queue: queue, load: .zero(sensorCount: 257))

        XCTAssertEqual(frame.sensorCount, 257)
        XCTAssertEqual(simulation.state.sensors.count, 257)
    }

    private func step(
        _ simulation: MetalRadialSimulation,
        queue: MTLCommandQueue,
        load: RadialBodyLoad
    ) async throws -> MetalRadialFrameResources {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try simulation.encodeStep(load: load, deltaTime: dt, commandBuffer: command)
        command.commit()
        await command.completed()
        XCTAssertEqual(command.status, .completed)
        try simulation.complete(frame: frame, commandBuffer: command)
        return frame
    }

    private func step<S: Sequence>(
        _ simulation: MetalRadialSimulation,
        queue: MTLCommandQueue,
        contacts: S
    ) async throws -> MetalRadialFrameResources where S.Element == RadialSurfaceContact {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let frame = try simulation.encodeStep(contacts: Array(contacts), deltaTime: dt, commandBuffer: command)
        command.commit()
        await command.completed()
        XCTAssertEqual(command.status, .completed)
        try simulation.complete(frame: frame, commandBuffer: command)
        return frame
    }

    private func makeState(expanded: Bool = false) -> RadialBubbleState {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1), center: .zero, targetRadius: 10,
            maxSegmentLength: 8, mass: 2
        )
        if expanded {
            state.birthProgress = 1
            for index in state.sensors.indices {
                state.sensors[index].length = 10
                state.sensors[index].targetLength = 10
            }
        }
        return state
    }

    private func contact(
        id: UInt64, sensor: Int, point: Vector2, normal: Vector2, penetration: Float
    ) -> RadialSurfaceContact {
        RadialSurfaceContact(
            sensorStartIndex: sensor, sensorEndIndex: (sensor + 1) % 8,
            barycentric: 0.3, point: point, normal: normal,
            penetration: penetration, relativeVelocity: .zero, sourceID: id
        )
    }

    private func assertLoad(
        _ actual: RadialBodyLoad,
        equals expected: RadialBodyLoad,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.force.x, expected.force.x, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.force.y, expected.force.y, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.torque, expected.torque, accuracy: 1e-5, file: file, line: line)
        XCTAssertEqual(actual.sensorCompression, expected.sensorCompression, file: file, line: line)
        XCTAssertEqual(actual.sensorPressureDeltas, expected.sensorPressureDeltas, file: file, line: line)
    }
}
