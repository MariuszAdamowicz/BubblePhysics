import XCTest
@testable import BubblePhysics

final class RadialSensorRemesherTests: XCTestCase {
    func testRequiredCountTracksCurrentCircumferenceWithoutMaximumCap() {
        var state = expandedBubble(radius: 1_000)

        let count = RadialSensorRemesher.requiredCount(for: state, maxSegmentLength: 1)

        XCTAssertGreaterThan(count, 6_000)
        state.sensors[0].length = 2_000
        XCTAssertGreaterThan(RadialSensorRemesher.requiredCount(for: state, maxSegmentLength: 1), count)
    }

    func testCollapsedBubbleUsesEightSensors() {
        let state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1),
            center: .zero,
            targetRadius: 1_000,
            maxSegmentLength: 1,
            mass: 1
        )

        XCTAssertEqual(RadialSensorRemesher.requiredCount(for: state, maxSegmentLength: 1), 8)
    }

    func testResamplingPreservesMeanRadiusAndBodyPose() {
        var state = expandedBubble(radius: 10)
        state.body.center = Vector2(x: 7, y: -2)
        state.body.linearVelocity = Vector2(x: 3, y: 4)
        state.body.angle = 0.7
        state.body.angularVelocity = -0.2
        for index in state.sensors.indices {
            state.sensors[index].length = 8 + Float(index)
            state.sensors[index].radialVelocity = Float(index) * 0.25
        }
        let originalMean = mean(state.sensors.map(\.length))
        let originalBody = state.body

        let result = RadialSensorRemesher.resample(state, to: 37)

        XCTAssertEqual(result.sensors.count, 37)
        XCTAssertEqual(mean(result.sensors.map(\.length)), originalMean, accuracy: 1e-5)
        XCTAssertEqual(result.body, originalBody)
    }

    func testResamplingInterpolatesIndentationAcrossAngularSeam() {
        var state = expandedBubble(radius: 10)
        state.sensors[0].length = 4
        state.sensors[1].length = 8
        state.sensors[7].length = 8

        let result = RadialSensorRemesher.resample(state, to: 32)

        XCTAssertEqual(result.sensors[1].length, result.sensors[31].length, accuracy: 1e-4)
        XCTAssertLessThan(result.sensors[0].length, result.sensors[1].length)
        XCTAssertLessThan(result.sensors[1].length, result.sensors[4].length)
    }

    func testRepeatedUpAndDownSamplingDoesNotCreateVisibleEnergy() {
        var state = expandedBubble(radius: 10)
        for index in state.sensors.indices {
            let angle = state.sensors[index].materialAngle
            state.sensors[index].length = 10 + 0.5 * cos(angle)
            state.sensors[index].radialVelocity = 0.2 * sin(angle)
        }
        let initialMean = mean(state.sensors.map(\.length))
        let initialEnergy = energy(state)

        for _ in 0..<20 {
            state = RadialSensorRemesher.resample(state, to: 31)
            state = RadialSensorRemesher.resample(state, to: 8)
        }

        XCTAssertEqual(mean(state.sensors.map(\.length)), initialMean, accuracy: 1e-4)
        XCTAssertLessThanOrEqual(energy(state), initialEnergy + 1e-3)
    }

    private func expandedBubble(radius: Float) -> RadialBubbleState {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1),
            center: .zero,
            targetRadius: radius,
            maxSegmentLength: max(1, radius),
            mass: 1
        )
        state.birthProgress = 1
        for index in state.sensors.indices {
            state.sensors[index].length = radius
            state.sensors[index].targetLength = radius
        }
        return state
    }

    private func mean(_ values: [Float]) -> Float {
        values.reduce(0, +) / Float(values.count)
    }

    private func energy(_ state: RadialBubbleState) -> Float {
        state.sensors.reduce(0) { result, sensor in
            let extensionValue = sensor.targetLength - sensor.length
            return result + extensionValue * extensionValue + sensor.radialVelocity * sensor.radialVelocity
        } / Float(state.sensors.count)
    }
}
