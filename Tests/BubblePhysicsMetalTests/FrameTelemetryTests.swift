import XCTest
@testable import BubblePhysics
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

    func testSnapshotCarriesFiniteContourTimingsAndCounters() {
        var telemetry = FrameTelemetry(windowSize: 4)
        telemetry.record(
            milliseconds: 12,
            timings: .init(contourMilliseconds: 7, remeshingMilliseconds: 1, renderingMilliseconds: 4),
            counters: .init(particleCount: 4200, segmentCount: 3900, candidatePairCount: 650, contactCount: 618, remeshOperationCount: 3, didOverflow: true, didEncounterNonFinite: false)
        )

        let snapshot = telemetry.snapshot
        XCTAssertEqual(snapshot.particleCount, 4200)
        XCTAssertEqual(snapshot.segmentCount, 3900)
        XCTAssertEqual(snapshot.candidatePairCount, 650)
        XCTAssertEqual(snapshot.contactCount, 618)
        XCTAssertEqual(snapshot.remeshOperationCount, 3)
        XCTAssertTrue(snapshot.didOverflow)
        XCTAssertFalse(snapshot.didEncounterNonFinite)
        XCTAssertEqual(snapshot.contourMilliseconds, 7)
        XCTAssertEqual(snapshot.remeshingMilliseconds, 1)
        XCTAssertEqual(snapshot.renderingMilliseconds, 4)
        XCTAssertTrue([snapshot.contourMilliseconds, snapshot.remeshingMilliseconds, snapshot.renderingMilliseconds].allSatisfy(\.isFinite))
    }

    func testResetClearsDetailedCountersAndFailureFreezesThem() {
        var telemetry = FrameTelemetry()
        let counters = FrameTelemetryCounters(particleCount: 10, segmentCount: 8, candidatePairCount: 4, contactCount: 3, remeshOperationCount: 1, didOverflow: false, didEncounterNonFinite: false)
        telemetry.record(milliseconds: 2, timings: .zero, counters: counters)
        telemetry.fail(.nonFinite)
        telemetry.record(milliseconds: 1, timings: .zero, counters: .init(particleCount: 99, segmentCount: 99, candidatePairCount: 99, contactCount: 99, remeshOperationCount: 99, didOverflow: true, didEncounterNonFinite: true))
        XCTAssertEqual(telemetry.snapshot.particleCount, 10)

        telemetry.reset()

        XCTAssertEqual(telemetry.snapshot.particleCount, 0)
        XCTAssertEqual(telemetry.snapshot.contactCount, 0)
        XCTAssertFalse(telemetry.snapshot.didOverflow)
        XCTAssertNil(telemetry.snapshot.failure)
    }

    func testSnapshotCarriesRadialWorldMetricsAndResetClearsThem() throws {
        var telemetry = FrameTelemetry()
        let world = try RadialWorldState(bubbles: [
            .collapsed(id: BubbleID(rawValue: 1), center: .zero, targetRadius: 20, maxSegmentLength: 8, mass: 2),
            .collapsed(id: BubbleID(rawValue: 2), center: Vector2(x: 10, y: 0), targetRadius: 50, maxSegmentLength: 8, mass: 4)
        ])
        let metrics = RadialWorldFrameMetrics(
            world: world, gpuFrameMilliseconds: 3.5, candidatePairCount: 1,
            environmentContactCount: 2, pairContactCount: 3, maximumPenetration: 4,
            remeshOperationCount: 5, substepCount: 2, didOverflow: false
        )

        telemetry.record(milliseconds: 4, timings: .zero, counters: .zero, worldRadial: metrics)

        XCTAssertEqual(telemetry.snapshot.worldRadial.bubbleCount, 2)
        XCTAssertEqual(telemetry.snapshot.worldRadial.sensorCount, 16)
        XCTAssertEqual(telemetry.snapshot.worldRadial.candidatePairCount, 1)
        XCTAssertEqual(telemetry.snapshot.worldRadial.pairContactCount, 3)
        XCTAssertEqual(telemetry.snapshot.worldRadial.substepCount, 2)
        telemetry.reset()
        XCTAssertEqual(telemetry.snapshot.worldRadial, .zero)
    }
}
