import Metal
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialEnduranceTests: XCTestCase {
    func testDiagnosticWorldSurvivesTenThousandStepsWithoutOverflowOrRunawayEnergy() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let scene = try RadialDiagnosticSceneFactory.make()
        let simulation = try MetalRadialWorldSimulation(device: device, world: scene.world)
        let targetRadii = Dictionary(uniqueKeysWithValues: scene.world.bubbles.map { ($0.id, $0.targetRadius) })
        for bubble in scene.world.bubbles { simulation.setTargetRadius(0, for: bubble.id) }
        var maximumObservedEnergy: Float = 0

        for stepIndex in 0..<10_000 {
            if stepIndex.isMultiple(of: 400) {
                let index = min(stepIndex / 400, scene.world.bubbles.count - 1)
                let bubble = scene.world.bubbles[index]
                simulation.setTargetRadius(targetRadii[bubble.id]!, for: bubble.id)
            }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let frame = try simulation.encodeStep(
                bounds: scene.bounds,
                polygons: stepIndex >= 2_500 ? [movingTriangle(step: stepIndex)] : [],
                deltaTime: 1 / 240,
                commandBuffer: command
            )
            command.commit()
            await command.completed()
            XCTAssertEqual(command.status, .completed)
            try simulation.complete(frame: frame, commandBuffer: command)

            let metrics = RadialWorldFrameMetrics(
                world: simulation.world, frame: frame, gpuFrameMilliseconds: 0,
                remeshOperationCount: 0, substepCount: 1
            )
            XCTAssertFalse(metrics.didOverflow)
            if metrics.didEncounterNonFinite {
                XCTFail("Non-finite state at step \(stepIndex)")
                return
            }
            maximumObservedEnergy = max(maximumObservedEnergy, metrics.kineticEnergy)
            let decisions = RadialWorldRemesher.plan(
                world: simulation.world, policy: .default, frameIndex: stepIndex + 1
            )
            if !decisions.isEmpty { try simulation.applyRemesh(decisions) }
        }

        let finalMetrics = RadialWorldFrameMetrics(world: simulation.world)
        XCTAssertFalse(finalMetrics.didEncounterNonFinite)
        XCTAssertLessThan(maximumObservedEnergy, 100_000_000)
        XCTAssertLessThan(finalMetrics.maximumBodySpeed, 200)
        XCTAssertLessThan(finalMetrics.maximumAngularSpeed, 50)
    }

    private func movingTriangle(step: Int) -> SimulationPolygonSnapshot {
        let state = KinematicTriangleMotion.default.sample(time: Double(step) / 120, isPaused: false)
        let local = [Vector2(x: -34, y: 26), Vector2(x: 34, y: 26), Vector2(x: 0, y: -38)]
        let c = cos(state.angleRadians), s = sin(state.angleRadians)
        return SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 99),
            mode: .kinematic,
            worldVertices: local.map { Vector2(x: $0.x * c - $0.y * s + state.position.x, y: $0.x * s + $0.y * c + state.position.y) },
            position: state.position,
            linearVelocity: state.linearVelocity,
            angularVelocity: state.angularVelocity
        )
    }
}
