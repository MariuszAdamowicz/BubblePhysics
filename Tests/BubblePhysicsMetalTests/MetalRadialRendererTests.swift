import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRadialRendererTests: XCTestCase {
    func testRendererBuildsOrderedFanFromRadialSurface() {
        let state = bubble(radius: 10)

        let geometry = MetalRadialRenderer.geometry(for: state)

        XCTAssertEqual(geometry.fillVertices.count, state.sensors.count * 3)
        for index in state.sensors.indices {
            XCTAssertEqual(geometry.fillVertices[index * 3], SIMD2(0, 0))
            XCTAssertEqual(geometry.fillVertices[index * 3 + 1], vector(state.surfacePoint(at: index)))
            XCTAssertEqual(geometry.fillVertices[index * 3 + 2], vector(state.surfacePoint(at: (index + 1) % state.sensors.count)))
        }
    }

    func testCollapsedContourDoesNotProduceNonFiniteVertices() {
        let state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1), center: Vector2(x: 5, y: 7),
            targetRadius: 100, maxSegmentLength: 8, mass: 1
        )

        let geometry = MetalRadialRenderer.geometry(for: state)

        XCTAssertTrue(geometry.fillVertices.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testLabelUsesBodyCenterAndBodyAngle() {
        var state = bubble(radius: 10)
        state.body.center = Vector2(x: 17, y: 23)
        state.body.angle = 1.25

        let pose = MetalRadialRenderer.labelPose(for: state)

        XCTAssertEqual(pose.position, SIMD2(17, 23))
        XCTAssertEqual(pose.angleRadians, 1.25)
    }

    private func bubble(radius: Float) -> RadialBubbleState {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: 1), center: .zero,
            targetRadius: radius, maxSegmentLength: 8, mass: 1
        )
        state.birthProgress = 1
        for index in state.sensors.indices {
            state.sensors[index].length = radius
            state.sensors[index].targetLength = radius
        }
        return state
    }

    private func vector(_ value: Vector2) -> SIMD2<Float> {
        SIMD2(value.x, value.y)
    }
}
