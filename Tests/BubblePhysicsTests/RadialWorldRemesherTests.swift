import XCTest
@testable import BubblePhysics

final class RadialWorldRemesherTests: XCTestCase {
    func testGrowingBubbleAddsSensorsBeforeUpperThresholdIsExceeded() throws {
        let bubble = expandedBubble(id: 1, radius: 20, sensorCount: 8, maxSegmentLength: 10)
        let world = try RadialWorldState(bubbles: [bubble])

        let decisions = RadialWorldRemesher.plan(world: world, policy: .default, frameIndex: 15)

        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions[0].bubbleID, bubble.id)
        XCTAssertGreaterThan(decisions[0].sensorCount, bubble.sensors.count)
        let rebuilt = try RadialWorldRemesher.apply(decisions, to: world)
        XCTAssertLessThanOrEqual(
            RadialSensorRemesher.maximumSegmentLength(in: rebuilt.bubbles[0]),
            bubble.maxSegmentLength * (1 + 1e-5)
        )
    }

    func testHysteresisPreventsCountOscillation() throws {
        let bubble = expandedBubble(id: 1, radius: 8, sensorCount: 16, maxSegmentLength: 5)
        let world = try RadialWorldState(bubbles: [bubble])
        let policy = RadialRemeshPolicy(
            upperSegmentLengthRatio: 1,
            lowerSegmentLengthRatio: 0.65,
            cooldownFrames: 15
        )

        XCTAssertTrue(RadialWorldRemesher.plan(world: world, policy: policy, frameIndex: 14).isEmpty)
        XCTAssertEqual(
            RadialWorldRemesher.plan(world: world, policy: policy, frameIndex: 15).first?.sensorCount,
            10
        )

        let nearThreshold = expandedBubble(id: 1, radius: 10, sensorCount: 13, maxSegmentLength: 5)
        let stableWorld = try RadialWorldState(bubbles: [nearThreshold])
        XCTAssertTrue(RadialWorldRemesher.plan(world: stableWorld, policy: policy, frameIndex: 30).isEmpty)
    }

    func testRemeshPreservesBodyMomentumAndMeanSurfaceState() throws {
        var bubble = expandedBubble(id: 7, radius: 20, sensorCount: 8, maxSegmentLength: 10)
        bubble.body.linearVelocity = Vector2(x: 4, y: -3)
        bubble.body.angularVelocity = 0.75
        for index in bubble.sensors.indices {
            bubble.sensors[index].radialVelocity = Float(index) * 0.2
            bubble.sensors[index].pressure = Float(index) * 0.3
        }
        let originalBody = bubble.body
        let originalMeans = means(bubble)
        let world = try RadialWorldState(bubbles: [bubble])
        let decisions = RadialWorldRemesher.plan(world: world, policy: .default, frameIndex: 15)

        let rebuilt = try RadialWorldRemesher.apply(decisions, to: world)

        XCTAssertEqual(rebuilt.bubbles[0].body, originalBody)
        assertMeans(means(rebuilt.bubbles[0]), equalTo: originalMeans)
    }

    func testConcurrentGrowthRebuildsContiguousRangesWithoutCrossTalk() throws {
        let first = expandedBubble(id: 11, radius: 20, sensorCount: 8, maxSegmentLength: 10)
        var second = expandedBubble(id: 22, radius: 30, sensorCount: 8, maxSegmentLength: 8)
        second.sensors[0].pressure = 99
        let world = try RadialWorldState(bubbles: [first, second])

        let decisions = RadialWorldRemesher.plan(world: world, policy: .default, frameIndex: 15)
        let rebuilt = try RadialWorldRemesher.apply(decisions, to: world)

        XCTAssertEqual(decisions.map(\.bubbleID), [first.id, second.id])
        XCTAssertEqual(rebuilt.ranges[0].sensorStart, 0)
        XCTAssertEqual(rebuilt.ranges[1].sensorStart, rebuilt.ranges[0].sensorCount)
        XCTAssertEqual(rebuilt.totalSensorCount, rebuilt.bubbles.map(\.sensors.count).reduce(0, +))
        XCTAssertEqual(rebuilt.bubbles.map(\.id), [first.id, second.id])
        XCTAssertLessThan(rebuilt.bubbles[0].sensors.map(\.pressure).max() ?? 0, 1)
        XCTAssertGreaterThan(rebuilt.bubbles[1].sensors.map(\.pressure).max() ?? 0, 1)
    }

    private func expandedBubble(
        id: Int,
        radius: Float,
        sensorCount: Int,
        maxSegmentLength: Float
    ) -> RadialBubbleState {
        var bubble = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: id),
            center: .zero,
            targetRadius: radius,
            maxSegmentLength: maxSegmentLength,
            mass: 1
        )
        bubble = RadialSensorRemesher.resample(bubble, to: sensorCount)
        bubble.birthProgress = 1
        for index in bubble.sensors.indices {
            bubble.sensors[index].length = radius
            bubble.sensors[index].targetLength = radius
        }
        return bubble
    }

    private func means(_ bubble: RadialBubbleState) -> [Float] {
        [
            bubble.sensors.map(\.length),
            bubble.sensors.map(\.radialVelocity),
            bubble.sensors.map(\.targetLength),
            bubble.sensors.map(\.pressure)
        ].map { $0.reduce(0, +) / Float($0.count) }
    }

    private func assertMeans(_ actual: [Float], equalTo expected: [Float]) {
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: 1e-5)
        }
    }
}
