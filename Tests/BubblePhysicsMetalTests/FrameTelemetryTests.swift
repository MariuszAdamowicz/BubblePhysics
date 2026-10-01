import XCTest
@testable import BubblePhysicsMetal

final class FrameTelemetryTests: XCTestCase {
    func testPercentilesAndFinitePresentation() {
        var telemetry = FrameTelemetry(windowSize: 5)
        [1.0, 2, 3, 4, 100].forEach { telemetry.record(milliseconds: $0) }
        XCTAssertEqual(telemetry.snapshot.p50Milliseconds, 3)
        XCTAssertEqual(telemetry.snapshot.p95Milliseconds, 100)
        XCTAssertTrue(telemetry.snapshot.fps.isFinite)
    }

    func testResetClearsWindowAndFailureStopsAggregation() {
        var telemetry = FrameTelemetry(windowSize: 10)
        telemetry.record(milliseconds: 10); telemetry.reset()
        XCTAssertEqual(telemetry.snapshot.sampleCount, 0)
        telemetry.record(milliseconds: 20); telemetry.fail(.nonFinite); telemetry.record(milliseconds: 1)
        XCTAssertEqual(telemetry.snapshot.sampleCount, 1)
        XCTAssertEqual(telemetry.snapshot.failure, .nonFinite)
    }
}
