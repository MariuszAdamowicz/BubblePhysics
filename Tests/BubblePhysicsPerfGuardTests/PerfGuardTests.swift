import Foundation
import Metal
import XCTest
@testable import BubblePhysicsPerfGuard

/// Logika porównania strażnika (P-B-8). Pomiary GPU są podstawiane, więc testy nie zależą od czasu.
@MainActor
final class PerfGuardTests: XCTestCase {
    private let device = "Test GPU"

    private func baseline(_ p95: Double, scene: String = "stress-300") -> PerfGuardBaseline {
        PerfGuardBaseline(device: device, scenes: [scene: PerfGuardScenePoint(
            p95Milliseconds: p95, runs: [p95], recordedAt: "2026-11-08T00:00:00Z", note: "test")])
    }

    private func guardRun(baseline: PerfGuardBaseline, slowdown: Double = 0,
                          measure: @escaping @MainActor (String) async throws -> Double) async throws -> PerfGuardReport {
        try await PerfGuard.check(scenes: ["stress-300"], baseline: baseline, device: device,
            runs: 5, injectedSlowdown: slowdown, measure: measure)
    }

    func testMedianOfFiveIgnoresSingleOutlierRun() {
        XCTAssertEqual(PerfGuard.median([8, 100, 8, 9, 7]), 8)
        XCTAssertEqual(PerfGuard.median([5, 1, 3]), 3)
    }

    func testResultWithinTenPercentOfBaselinePasses() async throws {
        let report = try await guardRun(baseline: baseline(8.0)) { _ in 8.8 }
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.results.first?.medianP95Milliseconds ?? 0, 8.8, accuracy: 1e-9)
    }

    func testResultOverTenPercentWorseThanBaselineFails() async throws {
        let report = try await guardRun(baseline: baseline(8.0)) { _ in 8.81 }
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.text.contains("FAIL"))
    }

    func testInjectedTwentyPercentSlowdownFailsTheGuard() async throws {
        // Ten sam pomiar bez spowolnienia przechodzi, ze spowolnieniem o 20% nie.
        let clean = try await guardRun(baseline: baseline(8.0), slowdown: 0) { _ in 8.0 }
        XCTAssertTrue(clean.passed)
        let slowed = try await guardRun(baseline: baseline(8.0), slowdown: 0.20) { _ in 8.0 }
        XCTAssertFalse(slowed.passed)
        XCTAssertEqual(slowed.results.first?.medianP95Milliseconds ?? 0, 9.6, accuracy: 1e-9)
    }

    func testMedianOfFiveRunsAbsorbsOneNoisyRun() async throws {
        var calls = 0
        let samples = [8.0, 8.1, 40.0, 7.9, 8.0]
        let report = try await guardRun(baseline: baseline(8.0)) { _ in
            defer { calls += 1 }
            return samples[calls]
        }
        XCTAssertEqual(calls, 5)
        XCTAssertTrue(report.passed)
        XCTAssertEqual(report.results.first?.runs, samples)
    }

    func testSceneWithoutBaselineFailsInsteadOfPassingSilently() async throws {
        let report = try await guardRun(baseline: baseline(8.0, scene: "mixed")) { _ in 1.0 }
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.text.contains("brak punktu odniesienia"))
    }

    func testBaselineFromAnotherDeviceFails() async throws {
        let other = PerfGuardBaseline(device: "Other GPU", scenes: baseline(8.0).scenes)
        let report = try await guardRun(baseline: other) { _ in 1.0 }
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.text.contains("Other GPU"))
    }

    func testRecordKeepsOtherScenesAndReplacesTheRecordedOne() throws {
        let existing = PerfGuardBaseline(device: device, scenes: baseline(8.0, scene: "mixed").scenes)
        let updated = existing.recording(scene: "stress-300", runs: [5, 6, 7, 8, 9],
            recordedAt: "2026-11-08T12:00:00Z", note: "n")
        XCTAssertEqual(updated.scenes["mixed"]?.p95Milliseconds, 8.0)
        XCTAssertEqual(updated.scenes["stress-300"]?.p95Milliseconds, 7)
        XCTAssertEqual(updated.scenes["stress-300"]?.runs, [5, 6, 7, 8, 9])
    }

    func testBaselineFileRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-guard-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let value = baseline(8.25)
        try value.write(to: url)
        XCTAssertEqual(try PerfGuardBaseline.load(from: url), value)
        XCTAssertNil(try PerfGuardBaseline.loadIfPresent(from: url.appendingPathExtension("missing")))
    }

    func testCommandLineParsing() throws {
        let options = try PerfGuardOptions.parse(["--record", "stress-300", "--runs", "2",
            "--baseline", "x.json", "--inject-slowdown", "0.2"])
        XCTAssertEqual(options.recordScene, "stress-300")
        XCTAssertEqual(options.runs, 2)
        XCTAssertEqual(options.baselinePath, "x.json")
        XCTAssertEqual(options.injectedSlowdown, 0.2)
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--nope"]))
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--record", "unknown-scene"]))
        let defaults = try PerfGuardOptions.parse([])
        XCTAssertEqual(defaults.runs, 5)
        XCTAssertEqual(defaults.measuredFrames, 300)
        XCTAssertNil(defaults.recordScene)
    }

    /// Okablowanie na prawdziwej scenie: krótki przebieg stress-300 daje skończone, dodatnie p95.
    func testStress300MeasurementReturnsPositiveFiniteP95() async throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let value = try await PerfGuard.measureStress300(device: gpu, warmupFrames: 2, measuredFrames: 5)
        XCTAssertTrue(value.isFinite && value > 0)
    }
}
