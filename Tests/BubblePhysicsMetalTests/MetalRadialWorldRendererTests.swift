import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialWorldRendererTests: XCTestCase {
    func testRendererBuildsOneFanAndLoopPerBubbleRange() throws {
        let world = try makeWorld(counts: [8, 13, 257])

        let plan = MetalRadialWorldRenderer.drawPlan(for: world)

        XCTAssertEqual(plan.map(\.sensorCount), [8, 13, 257])
        XCTAssertEqual(plan.map(\.fillVertexCount), [24, 39, 771])
        XCTAssertEqual(plan.map(\.outlineVertexCount), [9, 14, 258])
        XCTAssertEqual(plan.map(\.sensorStart), [0, 8, 21])
    }

    func testLabelsFollowMatchingBodyPose() throws {
        var world = try makeWorld(counts: [8, 13])
        var bubbles = world.bubbles
        bubbles[0].body.center = Vector2(x: 17, y: 23)
        bubbles[0].body.angle = 0.75
        bubbles[1].body.center = Vector2(x: -4, y: 31)
        bubbles[1].body.angle = -1.25
        world = try RadialWorldState(bubbles: bubbles)

        let poses = MetalRadialWorldRenderer.labelPoses(for: world)

        XCTAssertEqual(poses[bubbles[0].id], BubbleLabelPose(position: SIMD2(17, 23), angleRadians: 0.75))
        XCTAssertEqual(poses[bubbles[1].id], BubbleLabelPose(position: SIMD2(-4, 31), angleRadians: -1.25))
    }

    func testLargeAdaptiveContourHasNoVisibleEightPointFallback() throws {
        let world = try makeWorld(counts: [257])
        let plan = try XCTUnwrap(MetalRadialWorldRenderer.drawPlan(for: world).first)
        XCTAssertEqual(plan.sensorCount, 257)
        XCTAssertEqual(plan.fillVertexCount, 257 * 3)
    }

    func testCollapsedBubbleDoesNotProduceNonFiniteGeometry() throws {
        let bubble = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1), center: Vector2(x: 5, y: 7),
            targetRadius: 100, maxSegmentLength: 8, mass: 1
        )
        let world = try RadialWorldState(bubbles: [bubble])
        let geometry = MetalRadialWorldRenderer.geometry(for: world)
        XCTAssertTrue(geometry.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    private func makeWorld(counts: [Int]) throws -> RadialWorldState {
        try RadialWorldState(bubbles: counts.enumerated().map { index, count in
            var bubble = RadialBubbleState.collapsed(
                id: BubbleID(rawValue: index + 1), center: Vector2(x: Float(index * 30), y: 0),
                targetRadius: 20, maxSegmentLength: 5, mass: 1
            )
            bubble = RadialSensorRemesher.resample(bubble, to: count)
            bubble.birthProgress = 1
            for sensor in bubble.sensors.indices {
                bubble.sensors[sensor].length = 20
                bubble.sensors[sensor].targetLength = 20
            }
            return bubble
        })
    }
}
