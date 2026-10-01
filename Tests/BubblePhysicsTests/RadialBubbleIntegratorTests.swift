import XCTest
@testable import BubblePhysics

final class RadialBubbleIntegratorTests: XCTestCase {
    private let dt: Float = 1 / 60

    func testCollapsedBubbleBeginsGrowingSymmetricallyAndStaysFinite() {
        var state = makeCollapsedBubble()

        for _ in 0..<600 {
            RadialBubbleIntegrator.step(state: &state, load: .zero(sensorCount: state.sensors.count), deltaTime: dt)
            assertFinite(state)
        }

        XCTAssertGreaterThan(state.sensors[0].length, 0)
        for sensor in state.sensors.dropFirst() {
            XCTAssertEqual(sensor.length, state.sensors[0].length, accuracy: 1e-4)
        }
        XCTAssertEqual(state.birthProgress, 1, accuracy: 1e-5)
    }

    func testUnloadedBubbleConvergesTowardTargetRadiusWithoutOvershootExplosion() {
        var state = makeCollapsedBubble(targetRadius: 20)
        var maximum: Float = 0

        for _ in 0..<600 {
            RadialBubbleIntegrator.step(state: &state, load: .zero(sensorCount: state.sensors.count), deltaTime: dt)
            maximum = max(maximum, state.sensors.map(\.length).max() ?? 0)
        }

        XCTAssertEqual(meanRadius(state), 20, accuracy: 0.25)
        XCTAssertLessThan(maximum, 26)
        assertFinite(state)
    }

    func testLocalPressureCreatesSmoothLocalIndentation() {
        var state = makeExpandedBubble()
        var load = RadialBodyLoad.zero(sensorCount: state.sensors.count)
        load.sensorPressureDeltas[0] = 80

        for _ in 0..<90 {
            RadialBubbleIntegrator.step(state: &state, load: load, deltaTime: dt)
        }

        XCTAssertLessThan(state.sensors[0].length, state.sensors[1].length)
        XCTAssertLessThan(state.sensors[1].length, state.sensors[4].length)
        XCTAssertEqual(state.sensors[1].length, state.sensors[7].length, accuracy: 1e-4)
    }

    func testReleasedIndentationRecoversWithDecreasingEnergy() {
        var state = makeExpandedBubble()
        state.sensors[0].length = 2
        var windowMaxima: [Float] = []

        for window in 0..<10 {
            var maximum: Float = 0
            for _ in 0..<30 {
                RadialBubbleIntegrator.step(state: &state, load: .zero(sensorCount: state.sensors.count), deltaTime: dt)
                maximum = max(maximum, deformationEnergy(state))
            }
            if window > 0 { windowMaxima.append(maximum) }
        }

        for pair in zip(windowMaxima, windowMaxima.dropFirst()) {
            XCTAssertLessThanOrEqual(pair.1, pair.0 + 1e-4)
        }
        XCTAssertEqual(meanRadius(state), 10, accuracy: 0.2)
    }

    func testSymmetricPressureDoesNotTranslateOrRotateBody() {
        var state = makeExpandedBubble()
        var load = RadialBodyLoad.zero(sensorCount: state.sensors.count)
        load.sensorPressureDeltas = Array(repeating: 20, count: state.sensors.count)

        for _ in 0..<120 {
            RadialBubbleIntegrator.step(state: &state, load: load, deltaTime: dt)
        }

        XCTAssertEqual(state.body.center, .zero)
        XCTAssertEqual(state.body.linearVelocity, .zero)
        XCTAssertEqual(state.body.angle, 0)
        XCTAssertEqual(state.body.angularVelocity, 0)
    }

    func testCornerPinCanApproachZeroRadiusWithoutGoingNegativeOrNonFinite() {
        var state = makeExpandedBubble()
        var load = RadialBodyLoad.zero(sensorCount: state.sensors.count)
        load.sensorCompression[0] = 3
        load.sensorCompression[1] = 3
        load.sensorPressureDeltas[0] = 100_000
        load.sensorPressureDeltas[1] = 100_000

        for _ in 0..<600 {
            RadialBubbleIntegrator.step(state: &state, load: load, deltaTime: dt)
            assertFinite(state)
        }

        XCTAssertLessThan(state.sensors[0].length, 0.01)
        XCTAssertTrue(state.sensors.allSatisfy { $0.length >= 0 })
    }

    func testCyclicSensorRenumberingProducesEquivalentEvolution() {
        var first = makeExpandedBubble()
        for index in first.sensors.indices {
            first.sensors[index].length += Float(index % 3)
            first.sensors[index].radialVelocity = Float(index - 4) * 0.1
        }
        var second = first
        let shift = 3
        second.sensors = Array(first.sensors[shift...] + first.sensors[..<shift])
        var firstLoad = RadialBodyLoad.zero(sensorCount: first.sensors.count)
        firstLoad.sensorPressureDeltas[2] = 25
        var secondLoad = RadialBodyLoad.zero(sensorCount: second.sensors.count)
        secondLoad.sensorPressureDeltas = Array(firstLoad.sensorPressureDeltas[shift...] + firstLoad.sensorPressureDeltas[..<shift])

        for _ in 0..<20 {
            RadialBubbleIntegrator.step(state: &first, load: firstLoad, deltaTime: dt)
            RadialBubbleIntegrator.step(state: &second, load: secondLoad, deltaTime: dt)
        }

        for index in first.sensors.indices {
            let shiftedIndex = (index - shift + first.sensors.count) % first.sensors.count
            XCTAssertEqual(first.sensors[index].length, second.sensors[shiftedIndex].length, accuracy: 1e-5)
            XCTAssertEqual(first.sensors[index].radialVelocity, second.sensors[shiftedIndex].radialVelocity, accuracy: 1e-5)
        }
        XCTAssertEqual(first.body, second.body)
    }

    private func makeCollapsedBubble(targetRadius: Float = 10) -> RadialBubbleState {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1),
            center: .zero,
            targetRadius: targetRadius,
            maxSegmentLength: 8,
            mass: 2
        )
        state.dynamics = RadialBubbleMaterial(
            radialStiffness: 45,
            radialNonlinearity: 0.08,
            radialDamping: 14,
            neighborStiffness: 18,
            pressureResponse: 1,
            contactCorrection: 0.5,
            bodyLinearDrag: 2,
            bodyAngularDrag: 3,
            birthDuration: 0.5,
            maximumRadialSpeed: 100
        )
        return state
    }

    private func makeExpandedBubble() -> RadialBubbleState {
        var state = makeCollapsedBubble()
        state.birthProgress = 1
        for index in state.sensors.indices {
            state.sensors[index].length = 10
            state.sensors[index].targetLength = 10
        }
        return state
    }

    private func meanRadius(_ state: RadialBubbleState) -> Float {
        state.sensors.map(\.length).reduce(0, +) / Float(state.sensors.count)
    }

    private func deformationEnergy(_ state: RadialBubbleState) -> Float {
        state.sensors.reduce(0) { result, sensor in
            let extensionValue = sensor.targetLength - sensor.length
            return result + extensionValue * extensionValue + 0.02 * sensor.radialVelocity * sensor.radialVelocity
        }
    }

    private func assertFinite(
        _ state: RadialBubbleState,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertTrue(state.body.center.x.isFinite, file: file, line: line)
        XCTAssertTrue(state.body.center.y.isFinite, file: file, line: line)
        XCTAssertTrue(state.body.linearVelocity.x.isFinite, file: file, line: line)
        XCTAssertTrue(state.body.linearVelocity.y.isFinite, file: file, line: line)
        XCTAssertTrue(state.body.angle.isFinite, file: file, line: line)
        XCTAssertTrue(state.body.angularVelocity.isFinite, file: file, line: line)
        for sensor in state.sensors {
            XCTAssertTrue(sensor.length.isFinite, file: file, line: line)
            XCTAssertGreaterThanOrEqual(sensor.length, 0, file: file, line: line)
            XCTAssertTrue(sensor.radialVelocity.isFinite, file: file, line: line)
            XCTAssertTrue(sensor.targetLength.isFinite, file: file, line: line)
            XCTAssertTrue(sensor.pressure.isFinite, file: file, line: line)
        }
    }
}
