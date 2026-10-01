import CoreGraphics
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalWorldViewportTests: XCTestCase {
    func testIPhoneXWorldCornersFillMatchingDrawable() {
        let viewport = MetalWorldViewport(
            worldBounds: AABB(minimum: .zero, maximum: Vector2(x: 375, y: 812)),
            drawableSize: CGSize(width: 1125, height: 2436)
        )

        assert(viewport.worldToClip(SIMD2(0, 0)), equals: SIMD2(-1, 1))
        assert(viewport.worldToClip(SIMD2(375, 812)), equals: SIMD2(1, -1))
    }

    func testDifferentAspectRatioPreservesUniformWorldScale() {
        let viewport = MetalWorldViewport(
            worldBounds: AABB(minimum: .zero, maximum: Vector2(x: 375, y: 812)),
            drawableSize: CGSize(width: 1000, height: 1000)
        )

        let origin = viewport.worldToClip(.zero)
        let horizontal = viewport.worldToClip(SIMD2(100, 0))
        let vertical = viewport.worldToClip(SIMD2(0, 100))
        XCTAssertEqual(horizontal.x - origin.x, origin.y - vertical.y, accuracy: 0.000_01)
        XCTAssertGreaterThan(origin.x, -1)
        XCTAssertEqual(origin.y, 1, accuracy: 0.000_01)
    }

    func testViewPointRoundTripsThroughClipCoordinates() {
        let size = CGSize(width: 375, height: 812)
        let viewport = MetalWorldViewport(worldBounds: PrototypeSceneFactory.bounds, drawableSize: size)
        let world = SIMD2<Float>(123.5, 456.25)
        let clip = viewport.worldToClip(world)
        let viewPoint = SIMD2<Float>(
            (clip.x + 1) * 0.5 * Float(size.width),
            (1 - clip.y) * 0.5 * Float(size.height)
        )

        assert(viewport.viewToWorld(viewPoint), equals: world)
    }

    private func assert(
        _ actual: SIMD2<Float>,
        equals expected: SIMD2<Float>,
        accuracy: Float = 0.000_01,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.x, expected.x, accuracy: accuracy, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: accuracy, file: file, line: line)
    }
}
