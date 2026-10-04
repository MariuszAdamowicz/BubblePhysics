import XCTest
@testable import BubblePhysicsCore

final class BubbleModelTests: XCTestCase {
    func testValueTwoHasTwentyTwoPointRadius() {
        XCTAssertEqual(BubbleScale.radius(forValue: 2), 22, accuracy: 1e-12)
    }

    func testScaleIsMonotonic() {
        let values = stride(from: 2.0, through: 2048.0, by: 2.0)
        let radii = values.map(BubbleScale.radius(forValue:))

        XCTAssertTrue(zip(radii, radii.dropFirst()).allSatisfy(<))
        XCTAssertEqual(BubbleScale.radius(forValue: 8), 44, accuracy: 1e-12)
    }

    func testBubbleStartsAsFiniteOrderedCircle() {
        let bubble = Bubble.circular(
            center: BPVector(x: 10, y: 20),
            naturalRadius: 22,
            mass: 3,
            pointCount: 8
        )

        XCTAssertEqual(bubble.contour.count, 8)
        XCTAssertTrue(bubble.contour.allSatisfy { $0.position.isFinite })
        XCTAssertTrue(bubble.contour.allSatisfy {
            abs(($0.position - bubble.center).length - 22) < 1e-10
        })
        XCTAssertGreaterThan(signedArea(bubble.contour.map(\.position)), 0)
    }

    func testChamberContainsInteriorPoint() {
        let chamber = Chamber(
            minimum: BPVector(x: 5, y: 10),
            maximum: BPVector(x: 100, y: 200)
        )

        XCTAssertTrue(chamber.contains(BPVector(x: 50, y: 80), tolerance: 0))
        XCTAssertFalse(chamber.contains(BPVector(x: 101, y: 80), tolerance: 0))
    }

    private func signedArea(_ points: [BPVector]) -> Double {
        let successors = Array(points.dropFirst()) + Array(points.prefix(1))
        return zip(points, successors).reduce(0) {
            $0 + $1.0.cross($1.1)
        } * 0.5
    }
}
