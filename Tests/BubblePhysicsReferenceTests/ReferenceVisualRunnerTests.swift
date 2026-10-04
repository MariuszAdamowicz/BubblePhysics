import XCTest
@testable import BubblePhysicsReference

final class ReferenceVisualRunnerTests: XCTestCase {
    func testInitialPackingUsesTheFullBoardHeight() throws {
        var runner = try ReferenceVisualRunner()
        let snapshot = runner.advance(to: 0)
        let ys = snapshot.bubbles.map { $0.center.y }
        XCTAssertLessThan(try XCTUnwrap(ys.min()), 150)
        XCTAssertGreaterThan(try XCTUnwrap(ys.max()), 550)
    }
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

        XCTAssertEqual(snapshot.bubbles.count, 6)
        XCTAssertEqual(snapshot.contours.count, 6)
        XCTAssertEqual(snapshot.triangleVertices.count, 3)
        XCTAssertFalse(snapshot.lastReport.hasNonFiniteState)
        XCTAssertEqual(snapshot.valuesByBubbleID.count, 6)
    }

    func testChangingDensityRebuildsSceneWithTwentyFourBubbles() throws {
        var runner = try ReferenceVisualRunner()
        _ = runner.advance(to: 0)

        runner.setDensity(.twentyFour)
        let snapshot = runner.advance(to: 1)

        XCTAssertEqual(snapshot.bubbles.count, 24)
        XCTAssertEqual(snapshot.contours.count, 24)
        XCTAssertEqual(snapshot.valuesByBubbleID.count, 24)
        XCTAssertFalse(snapshot.lastReport.hasNonFiniteState)
    }

    func testResetAndOneHundredEightyFramesPreserveValueMapping() throws {
        var runner = try ReferenceVisualRunner()
        let initial = runner.advance(to: 0)
        var evolved = initial
        for frame in 1...180 { evolved = runner.advance(to: Double(frame) / 60) }
        XCTAssertEqual(evolved.valuesByBubbleID, initial.valuesByBubbleID)

        runner.reset()
        let reset = runner.advance(to: 0)
        XCTAssertEqual(reset.valuesByBubbleID, initial.valuesByBubbleID)
        XCTAssertEqual(reset.bubbles, initial.bubbles)
    }

    func testTriangleEdgesNeverPassThroughBubbleCenters() throws {
        var runner = try ReferenceVisualRunner()
        _ = runner.advance(to: 0)
        var snapshot = runner.advance(to: 1.0 / 60.0)

        runner.movePolygon(to: .init(x: 90, y: 350))
        for frame in 2...90 {
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
        XCTAssertFalse(snapshot.lastReport.hasNonFiniteState)
    }

    func testBubblePressedIntoWallReentersChamberAfterPolygonLeaves() throws {
        var runner = try ReferenceVisualRunner()
        _ = runner.advance(to: 0)
        var frame = 1
        runner.movePolygon(to: .init(x: 185, y: 650))
        var snapshot = runner.advance(to: Double(frame) / 60)
        for next in 2...50 { frame = next; snapshot = runner.advance(to: Double(frame) / 60) }

        runner.movePolygon(to: .init(x: 185, y: 350))
        for next in 51...350 { frame = next; snapshot = runner.advance(to: Double(frame) / 60) }

        let bottomBubble = try XCTUnwrap(snapshot.bubbles.first { snapshot.valuesByBubbleID[$0.id] == 2048 })
        XCTAssertLessThan(bottomBubble.center.y, ReferenceVisualScene.size.y - 2)
        XCTAssertLessThan(abs(bottomBubble.velocity.y), 10)
        XCTAssertFalse(snapshot.lastReport.hasNonFiniteState)
    }

    func testBubblesRecoverFromAllWallsAfterAggressiveDragging() throws {
        var runner = try ReferenceVisualRunner()
        _ = runner.advance(to: 0)
        var frame = 0
        var snapshot = runner.advance(to: 0)
        for target in [
            ReferenceVector2(x: 45, y: 50), .init(x: 330, y: 50),
            .init(x: 330, y: 650), .init(x: 45, y: 650), .init(x: 187, y: 350),
        ] {
            runner.movePolygon(to: target)
            for _ in 0..<75 { frame += 1; snapshot = runner.advance(to: Double(frame) / 60) }
        }
        runner.movePolygon(to: .init(x: 187, y: 350))
        for _ in 0..<600 { frame += 1; snapshot = runner.advance(to: Double(frame) / 60) }

        for bubble in snapshot.bubbles {
            let distances = [bubble.center.x, 375 - bubble.center.x, bubble.center.y, 700 - bubble.center.y]
            XCTAssertGreaterThan(
                try XCTUnwrap(distances.min()), 1,
                "bubble \(bubble.id.rawValue) remained at wall: center=\(bubble.center), velocity=\(bubble.velocity), report=\(snapshot.lastReport)"
            )
        }
        XCTAssertEqual(snapshot.lastReport.centerGuardCount, 0)
        XCTAssertFalse(snapshot.lastReport.hasNonFiniteState)
    }
}
