import Metal
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialEnduranceTests: XCTestCase {
    func testTenThousandStepsAcrossGrowthCompressionPinAndReleaseStayFinite() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1),
            center: Vector2(x: 60, y: 60),
            targetRadius: 36,
            maxSegmentLength: 5,
            mass: 8
        )
        let simulation = try MetalRadialSimulation(device: device, state: state)
        let openBounds = AABB(minimum: .zero, maximum: Vector2(x: 120, y: 120))
        let compressedBounds = AABB(minimum: .zero, maximum: Vector2(x: 78, y: 120))
        var maximumObservedEnergy: Float = 0

        for stepIndex in 0..<10_000 {
            let phase = stepIndex / 2_500
            let bounds = phase == 1 ? compressedBounds : openBounds
            let polygons = phase == 2 ? [pinningTriangle] : []
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let frame = try simulation.encodeStep(
                bounds: bounds,
                polygons: polygons,
                deltaTime: 1 / 120,
                commandBuffer: command
            )
            command.commit()
            await command.completed()
            XCTAssertEqual(command.status, .completed)
            try simulation.complete(frame: frame, commandBuffer: command)

            let metrics = RadialFrameMetrics(state: simulation.state, frame: frame)
            XCTAssertFalse(metrics.didOverflow)
            XCTAssertFalse(metrics.didEncounterNonFinite)
            XCTAssertGreaterThanOrEqual(metrics.minimumRadialLength, 0)
            maximumObservedEnergy = max(maximumObservedEnergy, metrics.kineticEnergy)
        }

        let finalMetrics = RadialFrameMetrics(state: simulation.state)
        XCTAssertFalse(finalMetrics.didEncounterNonFinite)
        // The deliberately abrupt pin phase may briefly spin the large-inertia body;
        // the limit guards runaway energy while allowing that finite transient.
        XCTAssertLessThan(maximumObservedEnergy, 2_000_000)
        XCTAssertLessThan(finalMetrics.bodySpeed, 20)
        XCTAssertLessThan(finalMetrics.angularSpeed, 10)
    }

    private var pinningTriangle: SimulationPolygonSnapshot {
        SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 99),
            mode: .kinematic,
            worldVertices: [
                Vector2(x: 52, y: 42),
                Vector2(x: 94, y: 60),
                Vector2(x: 52, y: 78)
            ],
            position: Vector2(x: 66, y: 60),
            linearVelocity: .zero,
            angularVelocity: 0
        )
    }
}
