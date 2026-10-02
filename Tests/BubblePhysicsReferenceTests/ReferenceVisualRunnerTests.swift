import XCTest
@testable import BubblePhysicsReference

final class ReferenceVisualRunnerTests: XCTestCase {
    func testLongPresentationGapRunsAtMostThreeFixedSteps() throws {
        var runner = try ReferenceVisualRunner()

        XCTAssertEqual(runner.advance(to: 10).stepsExecuted, 0)
        let snapshot = runner.advance(to: 11)

        XCTAssertEqual(snapshot.stepsExecuted, 3)
        XCTAssertEqual(snapshot.simulationTime, 3.0 / 60.0, accuracy: 0.000_001)
    }

    func testSnapshotContainsRenderStateAndFiniteReport() throws {
        var runner = try ReferenceVisualRunner()
        _ = runner.advance(to: 0)
        let snapshot = runner.advance(to: 1.0 / 60.0)

        XCTAssertEqual(snapshot.bubbles.count, 40)
        XCTAssertEqual(snapshot.contours.count, 40)
        XCTAssertEqual(snapshot.triangleVertices.count, 3)
        XCTAssertFalse(snapshot.lastReport.hasNonFiniteState)
    }

    func testTriangleEdgesNeverPassThroughBubbleCenters() throws {
        var runner = try ReferenceVisualRunner()
        _ = runner.advance(to: 0)
        var snapshot = runner.advance(to: 1.0 / 60.0)

        for frame in 2...180 {
            snapshot = runner.advance(to: Double(frame) / 60.0)
            for bubble in snapshot.bubbles {
                for edgeIndex in 0..<3 {
                    let endpoints = ReferenceSegmentEndpoints(
                        a: snapshot.triangleVertices[edgeIndex],
                        b: snapshot.triangleVertices[(edgeIndex + 1) % 3]
                    )
                    let closest = closestPoint(to: bubble.center, on: endpoints)
                    XCTAssertGreaterThan(closest.distanceSquared, 0.000_001)
                }
            }
        }
    }
}
