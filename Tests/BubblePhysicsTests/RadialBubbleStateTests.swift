import XCTest
@testable import BubblePhysics

final class RadialBubbleStateTests: XCTestCase {
    func testCollapsedBubbleHasOneMassBodyAndMasslessCoincidentSensors() {
        let center = Vector2(x: 12, y: 34)
        let state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 7),
            center: center,
            targetRadius: 40,
            maxSegmentLength: 6,
            mass: 5
        )

        XCTAssertEqual(state.id, BubbleID(rawValue: 7))
        XCTAssertEqual(state.body.center, center)
        XCTAssertEqual(state.body.mass, 5)
        XCTAssertEqual(state.sensors.count, 8)
        XCTAssertTrue(state.sensors.allSatisfy { $0.length == 0 })
        XCTAssertTrue(state.surfacePoints.allSatisfy { $0 == center && $0.x.isFinite && $0.y.isFinite })
    }

    func testSurfacePointsComeOnlyFromBodyPoseAndRadialLengths() {
        let body = RadialBubbleBody(
            center: Vector2(x: 10, y: 20),
            linearVelocity: .zero,
            angle: .pi / 2,
            angularVelocity: 0,
            mass: 2,
            momentOfInertia: 8
        )
        let sensors = [
            RadialSurfaceSensor(materialAngle: 0, length: 3, radialVelocity: 99, targetLength: 40, pressure: 500),
            RadialSurfaceSensor(materialAngle: .pi / 2, length: 4, radialVelocity: -99, targetLength: 2, pressure: 1)
        ]
        let state = RadialBubbleState(
            id: BubbleID(rawValue: 1),
            body: body,
            sensors: sensors,
            targetRadius: 40,
            birthProgress: 1,
            maxSegmentLength: 8,
            material: .default
        )

        assertVector(state.surfacePoint(at: 0), equals: Vector2(x: 10, y: 23))
        assertVector(state.surfacePoint(at: 1), equals: Vector2(x: 6, y: 20))
    }

    func testNegativeSensorLengthIsClampedToZero() {
        var sensor = RadialSurfaceSensor(
            materialAngle: 0,
            length: -10,
            radialVelocity: 0,
            targetLength: 3,
            pressure: 0
        )
        XCTAssertEqual(sensor.length, 0)

        sensor.length = -2
        XCTAssertEqual(sensor.length, 0)
    }

    func testChangingBodyPoseRigidlyTransformsEverySurfacePoint() {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1),
            center: .zero,
            targetRadius: 10,
            maxSegmentLength: 10,
            mass: 1
        )
        for index in state.sensors.indices {
            state.sensors[index].length = 2 + Float(index)
        }
        let original = state.surfacePoints

        state.body.center = Vector2(x: 4, y: -3)
        state.body.angle = .pi / 2

        for (before, after) in zip(original, state.surfacePoints) {
            let rotated = Vector2(x: -before.y + 4, y: before.x - 3)
            assertVector(after, equals: rotated)
        }
    }

    func testChangingTargetRadiusDoesNotInstantlyScaleCurrentSurface() {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1),
            center: .zero,
            targetRadius: 10,
            maxSegmentLength: 10,
            mass: 1
        )
        for index in state.sensors.indices {
            state.sensors[index].length = 3
        }
        let before = state.surfacePoints

        state.targetRadius = 100

        XCTAssertEqual(state.surfacePoints, before)
        XCTAssertEqual(state.targetRadius, 100)
    }

    private func assertVector(
        _ actual: Vector2,
        equals expected: Vector2,
        accuracy: Float = 1e-5,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }
}
