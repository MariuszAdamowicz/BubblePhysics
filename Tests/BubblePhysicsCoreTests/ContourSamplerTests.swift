import XCTest
@testable import BubblePhysicsCore

final class ContourSamplerTests: XCTestCase {
    func testPointCountFollowsCircumferenceWithoutUpperCap() {
        XCTAssertEqual(ContourSampler.pointCount(radius: 1, maxArcSpacing: 100), 8)
        XCTAssertEqual(ContourSampler.pointCount(radius: 22, maxArcSpacing: 8), 18)
        XCTAssertEqual(ContourSampler.pointCount(radius: 10_000, maxArcSpacing: 1), 62_832)
    }

    func testCircleIsCounterClockwiseAndUsesRequestedCenter() {
        let center = BPVector(x: 13, y: -7)
        let points = ContourSampler.makeCircle(center: center, radius: 22, maxArcSpacing: 8)

        XCTAssertEqual(points.count, 18)
        XCTAssertGreaterThan(signedArea(points), 0)
        XCTAssertEqual(mean(points).x, center.x, accuracy: 1e-12)
        XCTAssertEqual(mean(points).y, center.y, accuracy: 1e-12)
        XCTAssertTrue(points.allSatisfy { abs(($0.position - center).length - 22) < 1e-10 })
    }

    func testResamplingPreservesCenterAndClosedContinuity() {
        let source = [
            point(-4, -2), point(4, -2), point(4, 2), point(-4, 2)
        ]

        let result = ContourSampler.resampleClosedContour(source, targetCount: 16)

        XCTAssertEqual(result.count, 16)
        XCTAssertEqual(mean(result).x, 0, accuracy: 1e-12)
        XCTAssertEqual(mean(result).y, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(signedArea(result), 0)
        XCTAssertLessThanOrEqual(maximumClosedSegmentLength(result), 2.01)
    }

    func testResamplingStronglyFlattenedContourDoesNotSelfIntersect() {
        let source = [
            point(-10, 0), point(-3, -0.1), point(3, -0.1), point(10, 0),
            point(3, 0.1), point(-3, 0.1)
        ]

        let result = ContourSampler.resampleClosedContour(source, targetCount: 48)

        XCTAssertGreaterThan(signedArea(result), 0)
        XCTAssertFalse(hasSelfIntersection(result))
    }

    private func point(_ x: Double, _ y: Double) -> ContourPoint {
        ContourPoint(position: BPVector(x: x, y: y))
    }

    private func mean(_ points: [ContourPoint]) -> BPVector {
        points.reduce(.zero) { $0 + $1.position } / Double(points.count)
    }

    private func signedArea(_ points: [ContourPoint]) -> Double {
        guard !points.isEmpty else { return 0 }
        return points.indices.reduce(0) { area, index in
            area + points[index].position.cross(points[(index + 1) % points.count].position)
        } * 0.5
    }

    private func maximumClosedSegmentLength(_ points: [ContourPoint]) -> Double {
        points.indices.map {
            (points[($0 + 1) % points.count].position - points[$0].position).length
        }.max() ?? 0
    }

    private func hasSelfIntersection(_ points: [ContourPoint]) -> Bool {
        guard points.count >= 4 else { return false }
        for first in points.indices {
            let firstNext = (first + 1) % points.count
            for second in (first + 1)..<points.count {
                let secondNext = (second + 1) % points.count
                if first == second || firstNext == second || secondNext == first { continue }
                if first == 0 && secondNext == 0 { continue }
                if intersects(
                    points[first].position,
                    points[firstNext].position,
                    points[second].position,
                    points[secondNext].position
                ) { return true }
            }
        }
        return false
    }

    private func intersects(_ a: BPVector, _ b: BPVector, _ c: BPVector, _ d: BPVector) -> Bool {
        let ab = b - a
        let cd = d - c
        let first = ab.cross(c - a)
        let second = ab.cross(d - a)
        let third = cd.cross(a - c)
        let fourth = cd.cross(b - c)
        return first * second < -1e-12 && third * fourth < -1e-12
    }
}
