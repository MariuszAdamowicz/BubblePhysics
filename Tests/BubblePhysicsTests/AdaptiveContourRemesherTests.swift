import XCTest
@testable import BubblePhysics

final class AdaptiveContourRemesherTests: XCTestCase {
    func testSplitDividesMaterialLengthAndInterpolatesVelocity() {
        var contour = makeContour(count: 8, edgeLength: 4)
        contour.vertices[1] = .init(position: Vector2(x: 20, y: 0), previousPosition: Vector2(x: 18, y: 0))
        var remesher = AdaptiveContourRemesher(policy: .init(splitLength: 8, mergeLength: 2, persistenceFrames: 1, cooldownFrames: 0))

        let plan = remesher.plan(contour)
        let output = remesher.applying(plan, to: contour)

        XCTAssertEqual(output.vertices.count, 9)
        XCTAssertEqual(output.restLengths[0], 2, accuracy: 0.000_01)
        XCTAssertEqual(output.restLengths[1], 2, accuracy: 0.000_01)
        XCTAssertEqual(output.vertices[1].position, Vector2(x: 10, y: 0))
        XCTAssertEqual(output.vertices[1].previousPosition, Vector2(x: 9, y: 0))
    }

    func testMergeSumsMaterialLengthsAndNeverDropsBelowEightVertices() {
        var contour = makeContour(count: 9, edgeLength: 4)
        contour.vertices[1].position = Vector2(x: 0.5, y: 0)
        var remesher = AdaptiveContourRemesher(policy: .init(splitLength: 100, mergeLength: 1, persistenceFrames: 1, cooldownFrames: 0))
        let merged = remesher.applying(remesher.plan(contour), to: contour)

        XCTAssertEqual(merged.vertices.count, 8)
        XCTAssertEqual(merged.restLengths[0], 8, accuracy: 0.000_01)
        XCTAssertTrue(remesher.plan(merged).actions.isEmpty)
    }

    func testPersistenceAndCooldownPreventThresholdOscillation() {
        var contour = makeContour(count: 8, edgeLength: 4)
        contour.vertices[1].position = Vector2(x: 12, y: 0)
        var remesher = AdaptiveContourRemesher(policy: .init(splitLength: 8, mergeLength: 2, persistenceFrames: 2, cooldownFrames: 2))

        XCTAssertTrue(remesher.plan(contour).actions.isEmpty)
        let split = remesher.plan(contour)
        XCTAssertFalse(split.actions.isEmpty)
        let output = remesher.applying(split, to: contour)
        XCTAssertTrue(remesher.plan(output).actions.isEmpty)
        XCTAssertTrue(remesher.plan(output).actions.isEmpty)
    }

    func testSplitPreservesWeightedSpringEnergy() {
        var contour = makeContour(count: 8, edgeLength: 4)
        contour.vertices[1].position = Vector2(x: 10, y: 0)
        var remesher = AdaptiveContourRemesher(policy: .init(splitLength: 8, mergeLength: 1, persistenceFrames: 1, cooldownFrames: 0))
        let before = contour.springEnergy(material: .init(quadraticStiffness: 5, quarticStiffness: 0, drag: 0))

        let output = remesher.applying(remesher.plan(contour), to: contour)
        let after = output.springEnergy(material: .init(quadraticStiffness: 5, quarticStiffness: 0, drag: 0))

        XCTAssertEqual(after, before, accuracy: before * 0.02)
    }

    private func makeContour(count: Int, edgeLength: Float) -> AdaptiveContour {
        let vertices = (0..<count).map { index in
            AdaptiveContourVertex(position: Vector2(x: Float(index) * edgeLength, y: 0), previousPosition: Vector2(x: Float(index) * edgeLength, y: 0))
        }
        return AdaptiveContour(vertices: vertices, restLengths: Array(repeating: edgeLength, count: count))
    }
}
