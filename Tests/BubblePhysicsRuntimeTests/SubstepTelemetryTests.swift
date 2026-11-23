@testable import BubblePhysics
import BubblePhysicsNativeMetal
import XCTest

/// `NativeMetalFrameTelemetry` silnika 4.0.0 (P-B-27; G8-AC1): osobno liczba podkroków i przebudów siatki w klatce oraz czas GPU fizyki
/// i czas GPU konturu.
@MainActor
final class SubstepTelemetryTests: XCTestCase {
    /// Spokojna klatka: 1 podkrok, a oba czasy GPU są zmierzone osobno i dodatnie.
    func testQuietFrameReportsOneSubstepAndSeparateGPUTimes() async throws {
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: .zero, velocity: [30, 0]))
        }
        let recorded = try await ForceScene.run(world, frames: 30)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 30)
        for item in recorded {
            let telemetry = try XCTUnwrap(item.telemetry, "krok \(item.step): brak telemetrii")
            guard ForceScene.check(telemetry.substepCount == 1, "krok \(item.step): \(telemetry.substepCount) podkroków zamiast 1"),
                  ForceScene.check(telemetry.physicsGPUMilliseconds > 0, "krok \(item.step): czas GPU fizyki \(telemetry.physicsGPUMilliseconds)"),
                  ForceScene.check(telemetry.contourGPUMilliseconds > 0, "krok \(item.step): czas GPU konturu \(telemetry.contourGPUMilliseconds)")
            else { return }
        }
    }

    /// Klatki uderzenia: licznik podkroków z telemetrii równa się liczbie zapisanych podkroków, a szczyt jest wyraźnie ponad 1.
    func testImpactFramesReportTheCountOfCapturedSubsteps() async throws {
        var native = NativeMetalConfiguration.default
        native.captureSubsteps = true
        let world = try ForceScene.makeWorld(native: native) {
            try $0.add(ForceScene.bubble(1, at: [360 - 24 - 100, 0], velocity: [1000, 0])).add(ForceScene.wall(2, x: 360))
        }
        let recorded = try await ForceScene.run(world, frames: 40)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 40)
        var peak = 0
        for item in recorded {
            let count = try XCTUnwrap(item.telemetry, "krok \(item.step): brak telemetrii").substepCount
            peak = max(peak, count)
            guard ForceScene.check(count == item.samples.count, "krok \(item.step): telemetria \(count) podkroków, zapis \(item.samples.count)") else { return }
        }
        XCTAssertGreaterThan(peak, 5, "uderzenie 1000 j/s ma dać wyraźnie więcej niż 1 podkrok w klatce")
    }
}

/// Pola po XPBD, CCD i strażnikach baniek znikają z telemetrii (G8-AC1). Dopóki zadanie 14 ich nie usunie, ten test jest czerwony: to część
/// P-B-27, osobna klasa, żeby `SubstepTelemetryTests` była zielona po zadaniu 13.
final class ObsoleteSolverTelemetryTests: XCTestCase {
    func testTelemetryHasNoXPBDCCDOrGuardFields() {
        let labels = Set(Mirror(reflecting: NativeMetalFrameTelemetry()).children.compactMap(\.label))
        let obsolete: Set<String> = ["solverIterationCount", "ccdCandidateCount", "guardCorrectionCount", "cacheInvalidationCount",
                                     "cacheHitCount", "cacheResetCount"]
        XCTAssertEqual(labels.intersection(obsolete), [], "pola po XPBD, CCD i strażnikach zostały w telemetrii")
        XCTAssertTrue(labels.isSuperset(of: ["substepCount", "gridRebuildCount", "physicsGPUMilliseconds", "contourGPUMilliseconds"]))
    }
}
