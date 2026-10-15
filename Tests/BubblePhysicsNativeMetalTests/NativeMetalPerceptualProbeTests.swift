import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalPerceptualProbeTests: XCTestCase {
    func testNativeContourCanBeComparedWithCPUContourFromTheSameGPUPhysicsFrame() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let runner = try XCTUnwrap(NativeMetalWorldRunner(device: device, configuration: .init(solverIterationCount: 4)))
        var cpuScene = try ReferenceVisualSceneFactory.make(density: .six)
        var gpuScene = try ReferenceVisualSceneFactory.make(density: .six)
        var cpuCenter = ReferenceVisualSceneFactory.initialPolygonCenter
        var gpuCenter = ReferenceVisualSceneFactory.initialPolygonCenter
        var previousNativeProfiles: [ReferenceBubbleID: [Float]] = [:]
        var previousCPUProfiles: [ReferenceBubbleID: [Float]] = [:]
        var nativeVsCPUShape: [Double] = []
        var nativeShapeSteps: [Double] = []
        var cpuShapeSteps: [Double] = []
        var cpuContactAcceleration: [Double] = []
        var gpuContactAcceleration: [Double] = []
        var cpuPreviousVelocity = Dictionary(uniqueKeysWithValues: cpuScene.world.bubbles.map { ($0.id, $0.velocity) })
        var gpuPreviousVelocity = Dictionary(uniqueKeysWithValues: gpuScene.world.bubbles.map { ($0.id, $0.velocity) })

        for step in 1...120 {
            let phase = 2 * Float.pi * Float(step) / 120
            let target = ReferenceVector2(x: ReferenceVisualSceneFactory.initialPolygonCenter.x + 80 * sinf(phase),
                                          y: ReferenceVisualSceneFactory.initialPolygonCenter.y + 55 * cosf(phase * 2))
            moveTriangle(in: &cpuScene, center: &cpuCenter, target: target)
            moveTriangle(in: &gpuScene, center: &gpuCenter, target: target)
            _ = cpuScene.world.step()
            _ = await runner.step(world: &gpuScene.world, scenarioStep: step)
            XCTAssertEqual(runner.telemetry.backend, .nativeMetal)

            let nativeProfiles = profiles(bubbles: gpuScene.world.bubbles, contours: runner.contours)
            let cpuGeneratedContours = Dictionary(uniqueKeysWithValues: gpuScene.world.bubbles.map { bubble in
                (bubble.id, ReferenceContourGenerator.points(for: bubble, contacts: gpuScene.world.contacts.contacts,
                                                              segments: gpuScene.world.segments,
                                                              configuration: gpuScene.world.configuration))
            })
            let cpuProfiles = profiles(bubbles: gpuScene.world.bubbles, contours: cpuGeneratedContours)
            nativeVsCPUShape.append(meanProfileDifference(nativeProfiles, cpuProfiles))
            nativeShapeSteps.append(maximumProfileStep(from: previousNativeProfiles, to: nativeProfiles))
            cpuShapeSteps.append(maximumProfileStep(from: previousCPUProfiles, to: cpuProfiles))
            previousNativeProfiles = nativeProfiles
            previousCPUProfiles = cpuProfiles

            appendContactAccelerations(world: cpuScene.world, previousVelocity: &cpuPreviousVelocity,
                                       result: &cpuContactAcceleration)
            appendContactAccelerations(world: gpuScene.world, previousVelocity: &gpuPreviousVelocity,
                                       result: &gpuContactAcceleration)
        }

        let shapeP95 = percentile(nativeVsCPUShape, 0.95)
        let nativeStepP95 = percentile(nativeShapeSteps, 0.95)
        let cpuStepP95 = percentile(cpuShapeSteps, 0.95)
        let cpuAccelerationP95 = percentile(cpuContactAcceleration, 0.95)
        let gpuAccelerationP95 = percentile(gpuContactAcceleration, 0.95)
        print("perceptual_probe density=6 native_vs_cpu_geometry_contour_p95=\(shapeP95) native_contour_step_p95=\(nativeStepP95) cpu_geometry_contour_step_p95=\(cpuStepP95) cpu_contact_acceleration_p95=\(cpuAccelerationP95) gpu_contact_acceleration_p95=\(gpuAccelerationP95)")

        XCTAssertTrue([shapeP95, nativeStepP95, cpuStepP95, cpuAccelerationP95, gpuAccelerationP95].allSatisfy(\.isFinite))
        XCTAssertFalse(nativeVsCPUShape.isEmpty)
        XCTAssertFalse(cpuContactAcceleration.isEmpty)
        XCTAssertFalse(gpuContactAcceleration.isEmpty)
        // Kontur GPU może różnić się od CPU, ale nie może tworzyć własnego
        // lokalnego pofałdowania ani zmieniać kształtu wielokrotnie szybciej.
        XCTAssertLessThanOrEqual(shapeP95, 0.01)
        XCTAssertLessThanOrEqual(nativeStepP95, 0.07)
        // PBD koryguje pozycję natychmiast, ale ta korekta nie może być wprost
        // zamieniana na wielokrotnie większy od CPU impuls prędkości.
        XCTAssertLessThanOrEqual(gpuAccelerationP95, 160)
    }

    private func moveTriangle(in scene: inout ReferenceVisualScene, center: inout ReferenceVector2,
                              target: ReferenceVector2) {
        let oldVertices = ReferenceVisualSceneFactory.polygonVertices(localVertices: scene.polygonLocalVertices, center: center)
        let delta = target - center
        center = center + (delta.length > 18 ? delta * (18 / delta.length) : delta)
        let vertices = ReferenceVisualSceneFactory.polygonVertices(localVertices: scene.polygonLocalVertices, center: center)
        for index in vertices.indices {
            scene.world.updateSegment(.kinematicSegment(id: scene.polygonSegmentIDs[index],
                previousA: oldVertices[index], previousB: oldVertices[(index + 1) % 3],
                currentA: vertices[index], currentB: vertices[(index + 1) % 3],
                timeStep: 1 / 60, ownerID: scene.polygonOwnerID, collisionMode: .twoSided))
        }
    }

    private func profiles(bubbles: [ReferenceBubble], contours: [ReferenceBubbleID: [ReferenceVector2]])
        -> [ReferenceBubbleID: [Float]] {
        let bubblesByID = Dictionary(uniqueKeysWithValues: bubbles.map { ($0.id, $0) })
        return Dictionary(uniqueKeysWithValues: contours.compactMap { id, contour -> (ReferenceBubbleID, [Float])? in
            guard let bubble = bubblesByID[id], contour.count >= 32 else { return nil }
            return (id, (0..<32).map { sample in
                (contour[sample * contour.count / 32] - bubble.center).length / bubble.targetRadius
            })
        })
    }

    private func meanProfileDifference(_ first: [ReferenceBubbleID: [Float]],
                                       _ second: [ReferenceBubbleID: [Float]]) -> Double {
        let values = first.compactMap { id, left -> Double? in
            guard let right = second[id], left.count == right.count else { return nil }
            return Double(zip(left, right).map { abs($0 - $1) }.reduce(0, +)) / Double(left.count)
        }
        return values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)
    }

    private func maximumProfileStep(from previous: [ReferenceBubbleID: [Float]],
                                    to current: [ReferenceBubbleID: [Float]]) -> Double {
        current.reduce(0) { maximum, item in
            guard let before = previous[item.key], before.count == item.value.count else { return maximum }
            return max(maximum, Double(zip(before, item.value).map { abs($0 - $1) }.max() ?? 0))
        }
    }

    private func appendContactAccelerations(world: ReferenceWorld,
                                            previousVelocity: inout [ReferenceBubbleID: ReferenceVector2],
                                            result: inout [Double]) {
        let contacted = Set(world.contacts.contacts.flatMap { contact in
            [contact.bubbleA] + (contact.bubbleB.map { [$0] } ?? [])
        })
        for bubble in world.bubbles {
            defer { previousVelocity[bubble.id] = bubble.velocity }
            guard contacted.contains(bubble.id), let previous = previousVelocity[bubble.id] else { continue }
            result.append(Double((bubble.velocity - previous).length))
        }
    }

    private func percentile(_ values: [Double], _ percentile: Double) -> Double {
        let sorted = values.sorted()
        return sorted[Int((Double(sorted.count - 1) * percentile).rounded(.up))]
    }
}
