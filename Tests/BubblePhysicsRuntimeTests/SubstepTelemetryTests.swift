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

    /// Czas GPU fizyki to suma buforów podkroków, a czas konturu to bufor końca kroku: razem dają całkowity czas GPU klatki, także w klatce
    /// uderzenia z kilkoma parami buforów i przebudową siatki.
    func testPhysicsAndContourTimesAddUpToTheFrameGPUTime() async throws {
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: [360 - 24 - 100, 0], velocity: [1000, 0])).add(ForceScene.wall(2, x: 360))
        }
        let recorded = try await ForceScene.run(world, frames: 40)
        ForceScene.assertHealthy(world)
        var impactFrames = 0
        for item in recorded {
            let telemetry = try XCTUnwrap(item.telemetry, "krok \(item.step): brak telemetrii")
            guard ForceScene.check(telemetry.physicsGPUMilliseconds > 0 && telemetry.contourGPUMilliseconds > 0,
                                   "krok \(item.step): czasy \(telemetry.physicsGPUMilliseconds) i \(telemetry.contourGPUMilliseconds)"),
                  ForceScene.check(abs(telemetry.physicsGPUMilliseconds + telemetry.contourGPUMilliseconds - telemetry.gpuMilliseconds) < 1e-9,
                                   "krok \(item.step): fizyka + kontur ≠ całkowity czas GPU \(telemetry.gpuMilliseconds)")
            else { return }
            if telemetry.substepCount > 1 { impactFrames += 1 }
        }
        XCTAssertGreaterThan(impactFrames, 0, "scena ma mieć klatki z kilkoma podkrokami")
    }
}

extension SubstepTelemetryTests {
    /// P-B-40: spokojna klatka małego świata liczy się jedną dyspozycją: 1 bufor podkroków, ścieżka `.singleDispatch`, szerokość grupy
    /// z potoku (1...1024) i brak przebudów wymuszonych zapasem.
    func testQuietFrameReportsTheSingleDispatchPath() async throws {
        let world = try ForceScene.makeWorld {
            try $0.add(ForceScene.bubble(1, at: .zero, velocity: [30, 0]))
        }
        let recorded = try await ForceScene.run(world, frames: 20)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 20)
        for item in recorded {
            let telemetry = try XCTUnwrap(item.telemetry, "krok \(item.step): brak telemetrii")
            guard ForceScene.check(telemetry.executionPath == .singleDispatch, "krok \(item.step): ścieżka \(telemetry.executionPath)"),
                  ForceScene.check(telemetry.substepBufferCount == 1, "krok \(item.step): \(telemetry.substepBufferCount) buforów podkroków"),
                  ForceScene.check((1...1024).contains(telemetry.singleGroupWidth), "krok \(item.step): szerokość grupy \(telemetry.singleGroupWidth)"),
                  ForceScene.check(telemetry.gridRebuildCount == 0, "krok \(item.step): \(telemetry.gridRebuildCount) przebudów w spokojnej klatce")
            else { return }
        }
    }

    /// P-B-40: w ścieżce wielu dyspozycji `substepBufferCount` liczy pary buforów (dwa command buffery na parę), a `gridRebuildCount`
    /// tylko przebudowy wymuszone zapasem. Bańka w wolnej przestrzeni z czterokrotnie drobniejszym podziałem ma w pierwszej klatce
    /// kilka par (pierwsza para ma 2 podkroki), ale jej zapas obwiedni nigdy się nie wyczerpuje, więc przebudów jest 0.
    func testMultipleDispatchPairsAreCountedAndContinuationIsNotARebuild() async throws {
        var native = NativeMetalConfiguration.default
        native.forceMultipleDispatches = true
        native.substepSplitMultiplier = 8
        native.captureSubsteps = true
        let world = try ForceScene.makeWorld(native: native) {
            try $0.add(ForceScene.bubble(1, at: .zero, velocity: [30, 0]))
        }
        let recorded = try await ForceScene.run(world, frames: 10)
        ForceScene.assertHealthy(world)
        XCTAssertEqual(recorded.count, 10)
        for item in recorded {
            let telemetry = try XCTUnwrap(item.telemetry, "krok \(item.step): brak telemetrii")
            guard ForceScene.check(telemetry.executionPath == .multipleDispatches, "krok \(item.step): ścieżka \(telemetry.executionPath)"),
                  ForceScene.check(telemetry.substepBufferCount >= 1 && telemetry.commandBufferCount == 2 * telemetry.substepBufferCount,
                                   "krok \(item.step): \(telemetry.substepBufferCount) par, \(telemetry.commandBufferCount) command bufferów"),
                  ForceScene.check(telemetry.singleGroupWidth == 0, "krok \(item.step): szerokość grupy \(telemetry.singleGroupWidth)"),
                  ForceScene.check(telemetry.gridRebuildCount == 0,
                                   "krok \(item.step): \(telemetry.gridRebuildCount) przebudów, a zapas obwiedni się nie wyczerpał (\(telemetry.substepBufferCount) par)")
            else { return }
        }
        let first = try XCTUnwrap(recorded.first?.telemetry)
        XCTAssertGreaterThanOrEqual(first.substepCount, 8, "podział ×8 daje co najmniej 8 podkroków")
        XCTAssertGreaterThan(first.substepBufferCount, 1, "pierwsza para ma 2 podkroki, więc klatka z 8 podkrokami ma kilka par")
    }
}

/// Pola po XPBD, CCD i strażnikach baniek zniknęły z telemetrii (G8-AC1, P-B-27); osobna klasa od `SubstepTelemetryTests`, bo sprawdza brak pól.
final class ObsoleteSolverTelemetryTests: XCTestCase {
    func testTelemetryHasNoXPBDCCDOrGuardFields() {
        let labels = Set(Mirror(reflecting: NativeMetalFrameTelemetry()).children.compactMap(\.label))
        let obsolete: Set<String> = ["solverIterationCount", "ccdCandidateCount", "guardCorrectionCount", "cacheInvalidationCount",
                                     "cacheHitCount", "cacheResetCount"]
        XCTAssertEqual(labels.intersection(obsolete), [], "pola po XPBD, CCD i strażnikach zostały w telemetrii")
        XCTAssertTrue(labels.isSuperset(of: ["substepCount", "gridRebuildCount", "physicsGPUMilliseconds", "contourGPUMilliseconds"]))
    }
}
