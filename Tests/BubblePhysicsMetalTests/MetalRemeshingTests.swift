import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalRemeshingTests: XCTestCase {
    func testGPUSplitPreservesMaterialState() throws {
        let remesher = try makeRemesher()
        let contour = splitContour()

        let result = try remesher.remesh(
            contour,
            policy: .init(splitLength: 8, mergeLength: 1, persistenceFrames: 1, cooldownFrames: 0),
            capacity: 9
        )

        XCTAssertEqual(result.capacityGrowthRequired, nil)
        XCTAssertEqual(result.contour.vertices.count, 9)
        XCTAssertEqual(result.contour.vertices[1].position, Vector2(x: 10, y: 0))
        XCTAssertEqual(result.contour.vertices[1].previousPosition, Vector2(x: 9, y: 0))
        XCTAssertEqual(result.contour.restLengths[0], 2, accuracy: 0.000_01)
        XCTAssertEqual(result.contour.restLengths[1], 2, accuracy: 0.000_01)
        XCTAssertEqual(result.contour.stiffnessScales[0], 2, accuracy: 0.000_01)
        XCTAssertEqual(result.contour.stiffnessScales[1], 2, accuracy: 0.000_01)
    }

    func testInsufficientCapacityReportsGrowthWithoutChangingContour() throws {
        let remesher = try makeRemesher()
        let original = splitContour()

        let result = try remesher.remesh(
            original,
            policy: .init(splitLength: 8, mergeLength: 1, persistenceFrames: 1, cooldownFrames: 0),
            capacity: 8
        )

        XCTAssertEqual(result.capacityGrowthRequired, 9)
        XCTAssertEqual(result.contour, original)
    }

    func testRetryDoublesCapacityAtFrameBoundaryAndAppliesOnce() throws {
        let transaction = try MetalRemeshTransaction(initialCapacity: 8, device: makeDevice())
        let original = splitContour()

        let first = try transaction.apply(
            original,
            policy: .init(splitLength: 8, mergeLength: 1, persistenceFrames: 1, cooldownFrames: 0)
        )
        let second = try transaction.applyPendingAtFrameBoundary()

        XCTAssertEqual(first.capacityGrowthRequired, 9)
        XCTAssertEqual(first.contour, original)
        XCTAssertEqual(transaction.capacity, 16)
        XCTAssertNil(second.capacityGrowthRequired)
        XCTAssertEqual(second.contour.vertices.count, 9)
    }

    func testMinimumEightVerticesNeverMergeOnGPU() throws {
        let remesher = try makeRemesher()
        let contour = shortContour(count: 8)

        let result = try remesher.remesh(
            contour,
            policy: .init(splitLength: 100, mergeLength: 1, persistenceFrames: 1, cooldownFrames: 0),
            capacity: 8
        )

        XCTAssertNil(result.capacityGrowthRequired)
        XCTAssertEqual(result.contour, contour)
    }

    private func makeRemesher() throws -> MetalAdaptiveContourRemesher {
        try MetalAdaptiveContourRemesher(device: makeDevice())
    }

    private func makeDevice() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice())
    }

    private func splitContour() -> AdaptiveContour {
        var contour = shortContour(count: 8, spacing: 4)
        contour.vertices[1] = .init(position: Vector2(x: 20, y: 0), previousPosition: Vector2(x: 18, y: 0))
        return contour
    }

    private func shortContour(count: Int, spacing: Float = 0.5) -> AdaptiveContour {
        AdaptiveContour(
            vertices: (0..<count).map { index in
                let x = Float(index) * spacing
                return .init(position: Vector2(x: x, y: 0), previousPosition: Vector2(x: x, y: 0))
            },
            restLengths: Array(repeating: 4, count: count)
        )
    }
}
