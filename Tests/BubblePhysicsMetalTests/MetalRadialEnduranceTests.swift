import Metal
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialEnduranceTests: XCTestCase {
    func testTwentyFiveFPSDiagnosticFramesStayFiniteWhileTriangleMoves() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let scene = try RadialDiagnosticSceneFactory.make()
        let simulation = try MetalRadialWorldSimulation(device: device, world: scene.world)
        let targets = Dictionary(uniqueKeysWithValues: scene.world.bubbles.map { ($0.id, $0.targetRadius) })
        for bubble in scene.world.bubbles { simulation.setTargetRadius(0, for: bubble.id) }

        for frameIndex in 0..<600 {
            let currentTime = Double(frameIndex + 1) / 25
            if frameIndex.isMultiple(of: 38) {
                let index = min(frameIndex / 38, scene.world.bubbles.count - 1)
                let bubble = scene.world.bubbles[index]
                simulation.setTargetRadius(targets[bubble.id]!, for: bubble.id)
            }
            let schedule = RadialFrameStepSchedule.make(
                previousTime: Double(frameIndex) / 25, currentTime: currentTime,
                fixedStep: 1 / 30, maximumStepCount: 2
            )
            let steps = schedule.sampleTimes.map { time in
                MetalRadialWorldStep(
                    polygons: [movingTriangle(time: time)],
                    deltaTime: Float(schedule.deltaTime)
                )
            }
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let frame = try simulation.encodeSteps(bounds: scene.bounds, steps: steps, commandBuffer: command)
            command.commit()
            await command.completed()
            try simulation.complete(frame: frame, commandBuffer: command)

            let metrics = RadialWorldFrameMetrics(world: simulation.world, frame: frame)
            if metrics.didEncounterNonFinite {
                let bad = simulation.world.bubbles.filter { bubble in
                    ![bubble.body.center.x, bubble.body.center.y, bubble.body.linearVelocity.x,
                      bubble.body.linearVelocity.y, bubble.body.angle, bubble.body.angularVelocity]
                        .allSatisfy(\.isFinite)
                    || !bubble.sensors.flatMap { [$0.length, $0.radialVelocity, $0.pressure] }.allSatisfy(\.isFinite)
                }
                let motions = simulation.world.bubbles.map { ($0.id.rawValue, $0.body.linearVelocity, $0.body.angularVelocity) }
                XCTFail("frame \(frameIndex), energy \(metrics.kineticEnergy), speed \(metrics.maximumBodySpeed), angular \(metrics.maximumAngularSpeed), bad bubbles: \(bad.map { ($0.id.rawValue, $0.body) }), motions: \(motions)")
                return
            }
            let decisions = RadialWorldRemesher.plan(
                world: simulation.world, policy: .default, frameIndex: frameIndex + 1
            )
            if !decisions.isEmpty { try simulation.applyRemesh(decisions) }
        }
    }

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
                polygons: stepIndex >= 2_500 ? [movingTriangle(time: Double(stepIndex) / 120)] : [],
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

    private func movingTriangle(time: Double) -> SimulationPolygonSnapshot {
        let state = KinematicTriangleMotion.default.sample(time: time, isPaused: false)
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
