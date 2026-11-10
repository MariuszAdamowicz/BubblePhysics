import BubblePhysicsMetalRender
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

    // P-B-65, P-B-76, P-B-79: strażnik zna sceny stress-300, mieszaną, `decals` i `acceptance`.
    func testGuardKnowsStressMixedDecalsAndAcceptanceScenes() throws {
        XCTAssertEqual(PerfGuard.scenes, ["stress-300", "mixed", "decals", "acceptance"])
        XCTAssertNoThrow(try PerfGuardOptions.parse(["--record", "mixed"]))
        XCTAssertEqual(try PerfGuardOptions.parse(["--record", "decals"]).recordScene, "decals")
        XCTAssertEqual(try PerfGuardOptions.parse(["--record", "acceptance"]).recordScene, "acceptance")
    }

    // P-B-79: `--scene` zawęża pomiar do jednej sceny; nieznana scena to błąd; pozostałe opcje nie znikają.
    func testSceneOptionSelectsOneSceneAndRejectsUnknownOnes() throws {
        XCTAssertNil(try PerfGuardOptions.parse([]).scene)
        XCTAssertEqual(try PerfGuardOptions.parse(["--scene", "acceptance"]).scene, "acceptance")
        XCTAssertEqual(try PerfGuardOptions.parse(["--scene", "mixed", "--runs", "2"]).scene, "mixed")
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--scene", "unknown-scene"]))
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--scene"]))
    }

    // P-B-81: `--calibrate` i `--check-prediction` biorą ścieżkę raportu iPhone'a i nie biorą się nawzajem.
    func testCalibrateAndCheckPredictionOptionsTakeAReportPath() throws {
        let calibrate = try PerfGuardOptions.parse(["--scene", "acceptance", "--calibrate", "docs/benchmarks/r.md"])
        XCTAssertEqual(calibrate.calibrateReportPath, "docs/benchmarks/r.md")
        XCTAssertNil(calibrate.checkPredictionReportPath)
        let check = try PerfGuardOptions.parse(["--scene", "acceptance", "--check-prediction", "r.md"])
        XCTAssertEqual(check.checkPredictionReportPath, "r.md")
        XCTAssertNil(check.calibrateReportPath)
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--calibrate", "a.md", "--check-prediction", "b.md"]))
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--calibrate"]))
    }

    // P-B-76: nazwa sceny wybiera scenę benchmarku; każda nazwa strażnika ma scenę o tej samej nazwie.
    func testSceneNameSelectsTheBenchmarkScene() throws {
        XCTAssertEqual(try PerfGuard.benchmarkScene(named: "stress-300"), .stress300)
        XCTAssertEqual(try PerfGuard.benchmarkScene(named: "mixed"), .mixed)
        XCTAssertEqual(try PerfGuard.benchmarkScene(named: "decals"), .decals)
        XCTAssertEqual(try PerfGuard.benchmarkScene(named: "acceptance"), .acceptance)
        XCTAssertThrowsError(try PerfGuard.benchmarkScene(named: "unknown-scene"))
        for name in PerfGuard.scenes { XCTAssertEqual(try PerfGuard.benchmarkScene(named: name).name, name) }
    }

    // P-B-76: scena `decals` bez punktu odniesienia nie przechodzi po cichu, jak pozostałe.
    func testDecalsSceneWithoutBaselineFailsInsteadOfPassingSilently() async throws {
        let report = try await PerfGuard.check(scenes: ["decals"], baseline: baseline(8.0), device: device, runs: 5,
                                               measure: { _ in 1.0 })
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.text.contains("--record decals"))
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

    // P-B-7: skalowanie CPU przygotowania i publikacji kroku, 600 wobec 300 obiektów.
    func testScalingWithinTwoAndAHalfPasses() {
        let result = PerfGuard.evaluateScaling(small: 2.0, large: 5.0)
        XCTAssertTrue(result.passed)
        XCTAssertEqual(result.ratio, 2.5, accuracy: 1e-9)
        XCTAssertTrue(result.text.hasPrefix("scaling 600/300:"))
    }

    func testScalingOverTwoAndAHalfFails() {
        let result = PerfGuard.evaluateScaling(small: 2.0, large: 5.2)
        XCTAssertFalse(result.passed)
        XCTAssertTrue(result.text.hasPrefix("scaling 600/300:"))
        XCTAssertTrue(result.text.contains("FAIL"))
    }

    func testScalingWithNonFiniteOrZeroMeasurementFails() {
        XCTAssertFalse(PerfGuard.evaluateScaling(small: 0, large: 1).passed)
        XCTAssertFalse(PerfGuard.evaluateScaling(small: 1, large: .infinity).passed)
        XCTAssertFalse(PerfGuard.evaluateScaling(small: .nan, large: 1).passed)
    }

    func testScalingUsesMedianOfRunsForBothSizes() async throws {
        var calls: [Int] = []
        let small = [1.0, 1.1, 30.0, 0.9, 1.0], large = [2.0, 2.1, 2.2, 90.0, 1.9]
        var indexes = [300: 0, 600: 0]
        let result = try await PerfGuard.checkScaling(runs: 5) { count in
            calls.append(count)
            defer { indexes[count, default: 0] += 1 }
            return (count == 300 ? small : large)[indexes[count] ?? 0]
        }
        XCTAssertEqual(calls.filter { $0 == 300 }.count, 5)
        XCTAssertEqual(calls.filter { $0 == 600 }.count, 5)
        XCTAssertEqual(result.small, 1.0, accuracy: 1e-9)
        XCTAssertEqual(result.large, 2.1, accuracy: 1e-9)
        XCTAssertTrue(result.passed)
    }

    func testReportFailsAndPrintsScalingLineWhenScalingFails() async throws {
        let report = try await PerfGuard.check(scenes: ["stress-300"], baseline: baseline(8.0), device: device,
            runs: 5, measure: { _ in 8.0 }, scalingMeasure: { count in count == 300 ? 1.0 : 4.0 })
        XCTAssertFalse(report.passed)
        XCTAssertTrue(report.text.contains("scaling 600/300:"))
        let ok = try await PerfGuard.check(scenes: ["stress-300"], baseline: baseline(8.0), device: device,
            runs: 5, measure: { _ in 8.0 }, scalingMeasure: { count in count == 300 ? 1.0 : 2.0 })
        XCTAssertTrue(ok.passed)
        XCTAssertTrue(ok.text.contains("scaling 600/300:"))
    }

    func testInjectedSlowdownDoesNotChangeScalingRatio() async throws {
        let report = try await PerfGuard.check(scenes: ["stress-300"], baseline: baseline(8.0), device: device,
            runs: 5, injectedSlowdown: 0.2, measure: { _ in 6.0 },
            scalingMeasure: { count in count == 300 ? 1.0 : 2.0 })
        XCTAssertEqual(report.scaling?.ratio ?? 0, 2.0, accuracy: 1e-9)
    }

    /// Okablowanie skalowania na prawdziwej scenie: krótki przebieg daje skończone, dodatnie czasy CPU.
    func testHostCPUMeasurementForBubbleCountIsPositiveAndFinite() async throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let value = try await PerfGuard.measureHostCPU(device: gpu, bubbleCount: 300, warmupFrames: 2, measuredFrames: 5)
        XCTAssertTrue(value.isFinite && value > 0)
    }

    /// Okablowanie sceny `decals` na prawdziwym świecie: krótki przebieg daje skończone, dodatnie p95 i bezpieczne klatki.
    func testDecalsMeasurementReturnsPositiveFiniteP95() async throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let value = try await PerfGuard.measureScene(.decals, device: gpu, warmupFrames: 2, measuredFrames: 5)
        XCTAssertTrue(value.isFinite && value > 0)
    }

    /// Okablowanie na prawdziwej scenie: krótki przebieg stress-300 daje skończone, dodatnie p95.
    func testStress300MeasurementReturnsPositiveFiniteP95() async throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let value = try await PerfGuard.measureStress300(device: gpu, warmupFrames: 2, measuredFrames: 5)
        XCTAssertTrue(value.isFinite && value > 0)
    }

    // MARK: - Prognoza p95 iPhone'a X (P-B-81)

    /// Raport iPhone'a z liniami składowymi: liczby z pomiaru 2026-11-10 (v2-iphone-x-2026-11-10-retest.md) plus nowe linie.
    private func report(p95: Double = 24.2744, commit: String? = "a367bd0567f01d4ccf142691958c53e6249e8d3f") -> String {
        let header = commit.map { "- Mierzony kod: `\($0)`, gałąź `feature/engine-foundations`.\n\n" } ?? ""
        return header + """
        ```text
        path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
        device=Apple A11 GPU
        scene=acceptance; solver_iteration_limit=4
        render_px=1125x2436
        warmup=30; measured=300
        p95_ms=\(String(format: "%.4f", p95)); max_ms=25.4957
        gpu_p95_ms=14.7964; host_non_gpu_p95_ms=9.6007
        host_preparation_p95_ms=3.9000; host_publication_p95_ms=3.1000
        host_encoding_p95_ms=1.9882; host_waiting_p95_ms=15.8875
        gpu_physics_p95_ms=12.0000; gpu_render_estimate_ms=2.7964
        failed_frames=0
        ```
        """
    }

    private let mac = StageComponents(hostPreparationMilliseconds: 1.0, hostEncodingMilliseconds: 0.57,
        hostWaitingMilliseconds: 1.0, hostPublicationMilliseconds: 0.9, hostNonGPUMilliseconds: 3.0,
        gpuMilliseconds: 1.9, gpuPhysicsMilliseconds: 1.6)
    // Reszta Maca (oczekiwanie ponad GPU) = host_non_gpu − przygotowanie − kodowanie − publikacja = 0,53 ms (> 0,1 ms),
    // a iPhone'a 9,6007 − 3,9 − 1,9882 − 3,1 = 0,6125 ms.
    private let iPhoneRest = 9.6007 - 3.9 - 1.9882 - 3.1

    private func calibration() throws -> DeviceCalibration {
        try DevicePrediction.calibrate(iPhone: DevicePrediction.parse(report: report()), mac: mac,
                                       commit: "a367bd0567f01d4ccf142691958c53e6249e8d3f")
    }

    func testParserReadsEveryComponentLineAndTheCommitFromAnIPhoneReport() throws {
        let parsed = try DevicePrediction.parse(report: report())
        XCTAssertEqual(parsed.commit, "a367bd0567f01d4ccf142691958c53e6249e8d3f")
        XCTAssertEqual(parsed.p95Milliseconds, 24.2744, accuracy: 1e-9)
        XCTAssertEqual(parsed.components, StageComponents(hostPreparationMilliseconds: 3.9, hostEncodingMilliseconds: 1.9882,
            hostWaitingMilliseconds: 15.8875, hostPublicationMilliseconds: 3.1, hostNonGPUMilliseconds: 9.6007,
            gpuMilliseconds: 14.7964, gpuPhysicsMilliseconds: 12.0))
        XCTAssertNil(try DevicePrediction.parse(report: report(commit: nil)).commit)
    }

    func testParserReadsTheCommitFromTheHeaderTheOwnerWritesWithTheWordCommit() throws {
        // Raport kalibracyjny właściciela ma nagłówek „Mierzony commit:", nie „Mierzony kod:".
        let owner = report(commit: nil).replacingOccurrences(of: "```text",
            with: "- Mierzony commit: `4adf6122cd83e37b9f506ea167eca64c993d39a6` (`feature/engine-foundations`).\n\n```text")
        XCTAssertEqual(try DevicePrediction.parse(report: owner).commit, "4adf6122cd83e37b9f506ea167eca64c993d39a6")
    }

    func testParserTellsApartGPUP95FromFramePercentileLines() throws {
        // `gpu_p95_ms=` kończy się tak samo jak `p95_ms=`; klucze muszą pasować w całości.
        let parsed = try DevicePrediction.parse(report: report())
        XCTAssertNotEqual(parsed.p95Milliseconds, parsed.components.gpuMilliseconds)
    }

    func testParserRejectsTheReportFrom20261110WithTheNameOfTheFirstMissingLine() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let old = try String(contentsOf: root.appendingPathComponent("docs/benchmarks/v2-iphone-x-2026-11-10-retest.md"),
                             encoding: .utf8)
        XCTAssertThrowsError(try DevicePrediction.parse(report: old)) { error in
            XCTAssertEqual(error as? DevicePredictionError, .missingLine("host_preparation_p95_ms"))
        }
    }

    func testParserNamesEachMissingLineAndRejectsNonNumericValues() throws {
        for key in ["p95_ms", "gpu_p95_ms", "host_non_gpu_p95_ms", "host_preparation_p95_ms", "host_encoding_p95_ms",
                    "host_waiting_p95_ms", "host_publication_p95_ms", "gpu_physics_p95_ms"] {
            let text = report().split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in
                    line.split(separator: ";", omittingEmptySubsequences: false)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("\(key)=") }
                        .joined(separator: ";")
                }.joined(separator: "\n")
            XCTAssertThrowsError(try DevicePrediction.parse(report: text), key) { error in
                XCTAssertEqual(error as? DevicePredictionError, .missingLine(key))
            }
        }
        let broken = report().replacingOccurrences(of: "gpu_physics_p95_ms=12.0000", with: "gpu_physics_p95_ms=abc")
        XCTAssertThrowsError(try DevicePrediction.parse(report: broken)) { error in
            XCTAssertEqual(error as? DevicePredictionError, .invalidValue(line: "gpu_physics_p95_ms", value: "abc"))
        }
        let infinite = report().replacingOccurrences(of: "gpu_physics_p95_ms=12.0000", with: "gpu_physics_p95_ms=inf")
        XCTAssertThrowsError(try DevicePrediction.parse(report: infinite))
    }

    func testCalibrationStoresCommitComponentsAndRatiosFromOneCommit() throws {
        let value = try calibration()
        XCTAssertEqual(value.commit, "a367bd0567f01d4ccf142691958c53e6249e8d3f")
        XCTAssertEqual(value.mac, mac)
        XCTAssertEqual(value.iphone.hostNonGPUMilliseconds, 9.6007, accuracy: 1e-9)
        XCTAssertEqual(value.ratios.cpu, 9.6007 / 3.0, accuracy: 1e-9)
        XCTAssertEqual(value.ratios.physics, 12.0 / 1.6, accuracy: 1e-9)
        XCTAssertEqual(value.iphoneRenderMilliseconds, 14.7964 - 12.0, accuracy: 1e-9)
    }

    func testCalibrationRejectsAReportFromAnotherCommitAndNonPositiveMacComponents() throws {
        let parsed = try DevicePrediction.parse(report: report())
        XCTAssertThrowsError(try DevicePrediction.calibrate(iPhone: parsed, mac: mac, commit: "0000000000000000000000000000000000000000")) { error in
            XCTAssertEqual(error as? DevicePredictionError, .commitMismatch(report: "a367bd0567f01d4ccf142691958c53e6249e8d3f",
                current: "0000000000000000000000000000000000000000"))
        }
        // Skrócony SHA tego samego commitu to ten sam commit.
        XCTAssertNoThrow(try DevicePrediction.calibrate(iPhone: parsed, mac: mac, commit: "a367bd0"))
        // Raport bez commitu w nagłówku nie wiąże się z żadnym kodem, więc nie może być kalibracją.
        let anonymous = try DevicePrediction.parse(report: report(commit: nil))
        XCTAssertThrowsError(try DevicePrediction.calibrate(iPhone: anonymous, mac: mac, commit: "abc1234")) { error in
            XCTAssertEqual(error as? DevicePredictionError, .missingCommit)
        }
        var noCPU = mac
        noCPU.hostNonGPUMilliseconds = 0
        XCTAssertThrowsError(try DevicePrediction.calibrate(iPhone: parsed, mac: noCPU, commit: "a367bd0")) { error in
            XCTAssertEqual(error as? DevicePredictionError, .nonPositiveComponent("hostNonGPUMilliseconds"))
        }
        var noPhysics = mac
        noPhysics.gpuPhysicsMilliseconds = 0
        XCTAssertThrowsError(try DevicePrediction.calibrate(iPhone: parsed, mac: noPhysics, commit: "a367bd0")) { error in
            XCTAssertEqual(error as? DevicePredictionError, .nonPositiveComponent("gpuPhysicsMilliseconds"))
        }
    }

    func testCalibrationFileUsesTheKeysTheVerifyStepsRead() throws {
        let value = try calibration()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("calibration-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try value.write(to: url)
        XCTAssertEqual(try DeviceCalibration.load(from: url), value)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(json["commit"] as? String, value.commit)
        XCTAssertEqual((json["ratios"] as? [String: Double])?["cpu"] ?? 0, value.ratios.cpu, accuracy: 1e-12)
        XCTAssertEqual((json["ratios"] as? [String: Double])?["physics"] ?? 0, value.ratios.physics, accuracy: 1e-12)
        XCTAssertEqual(json["iphoneRenderMilliseconds"] as? Double ?? 0, value.iphoneRenderMilliseconds, accuracy: 1e-12)
        let macKeys = Set((json["mac"] as? [String: Double] ?? [:]).keys)
        XCTAssertEqual(macKeys, ["hostPreparationMilliseconds", "hostEncodingMilliseconds", "hostWaitingMilliseconds",
            "hostPublicationMilliseconds", "hostNonGPUMilliseconds", "gpuMilliseconds", "gpuPhysicsMilliseconds"])
        XCTAssertEqual(Set((json["iphone"] as? [String: Double] ?? [:]).keys), macKeys)
    }

    // MARK: - Prognoza CPU ze składowych (P-B-91)

    /// Klatka Maca z podanymi składowymi CPU; `host_non_gpu` to ich suma (reszta = oczekiwanie ponad GPU).
    private func macFrame(preparation: Double = 1.0, encoding: Double = 0.57, publication: Double = 0.9,
                          rest: Double = 0.53) -> StageComponents {
        StageComponents(hostPreparationMilliseconds: preparation, hostEncodingMilliseconds: encoding,
            hostWaitingMilliseconds: 1.0, hostPublicationMilliseconds: publication,
            hostNonGPUMilliseconds: preparation + encoding + publication + rest, gpuMilliseconds: 1.9,
            gpuPhysicsMilliseconds: 1.6)
    }

    // P-B-91: na commicie kalibracji suma składowych równa `host_non_gpu_p95_ms` raportu, składowa po składowej.
    func testPredictionAtTheCalibrationCommitSumsTheComponentsToHostNonGPUOfTheReport() throws {
        let prediction = DevicePrediction.predict(calibration: try calibration(), mac: mac)
        XCTAssertEqual(prediction.cpuMilliseconds, 9.6007, accuracy: 1e-9)
        let parts = prediction.cpuComponents
        XCTAssertEqual(parts.preparationMilliseconds, 3.9, accuracy: 1e-9)
        XCTAssertEqual(parts.encodingMilliseconds, 1.9882, accuracy: 1e-9)
        XCTAssertEqual(parts.publicationMilliseconds, 3.1, accuracy: 1e-9)
        XCTAssertEqual(parts.waitingMilliseconds, iPhoneRest, accuracy: 1e-9)
        XCTAssertEqual(parts.preparationMilliseconds + parts.encodingMilliseconds + parts.publicationMilliseconds
            + parts.waitingMilliseconds, prediction.cpuMilliseconds, accuracy: 1e-9)
        XCTAssertEqual(prediction.p95Milliseconds, 9.6007 + 14.7964, accuracy: 1e-9)
        XCTAssertEqual(prediction.physicsMilliseconds, 12.0, accuracy: 1e-9)
        XCTAssertEqual(prediction.renderMilliseconds, 14.7964 - 12.0, accuracy: 1e-9)
        XCTAssertEqual(prediction.cpuMilliseconds + prediction.physicsMilliseconds + prediction.renderMilliseconds,
                       prediction.p95Milliseconds, accuracy: 1e-9)
    }

    // P-B-91: zmiana jednej składowej na Macu przesuwa prognozę tylko o jej własny mnożnik `iphone_i / mac_i`.
    func testChangingOneComponentOnTheMacMovesThePredictionOnlyByItsOwnRatio() throws {
        let value = try calibration()
        let base = DevicePrediction.predict(calibration: value, mac: mac)
        // (nazwa, zmieniona klatka Maca, mnożnik tej składowej, ścieżka do składowej prognozy)
        let cases: [(String, StageComponents, Double, KeyPath<CPUComponents, Double>)] = [
            ("przygotowanie", macFrame(preparation: 0.5), 3.9 / 1.0, \.preparationMilliseconds),
            ("kodowanie", macFrame(encoding: 0.3), 1.9882 / 0.57, \.encodingMilliseconds),
            ("publikacja", macFrame(publication: 0.4), 3.1 / 0.9, \.publicationMilliseconds),
            ("oczekiwanie", macFrame(rest: 0.33), iPhoneRest / 0.53, \.waitingMilliseconds)]
        for (name, changed, ratio, part) in cases {
            let moved = DevicePrediction.predict(calibration: value, mac: changed)
            let macDelta = changed.hostNonGPUMilliseconds - mac.hostNonGPUMilliseconds
            XCTAssertNotEqual(macDelta, 0, name)
            XCTAssertEqual(moved.cpuMilliseconds - base.cpuMilliseconds, ratio * macDelta, accuracy: 1e-9,
                "\(name): przesunięcie prognozy = własny mnożnik · zmiana na Macu")
            for (otherName, _, _, other) in cases where otherName != name {
                XCTAssertEqual(moved.cpuComponents[keyPath: other], base.cpuComponents[keyPath: other], accuracy: 1e-9,
                    "zmiana „\(name)\" nie rusza składowej „\(otherName)\"")
            }
            XCTAssertEqual(moved.physicsMilliseconds, base.physicsMilliseconds, accuracy: 1e-12, name)
            XCTAssertEqual(moved.renderMilliseconds, base.renderMilliseconds, accuracy: 1e-12, name)
            XCTAssertEqual(moved.cpuComponents[keyPath: part] - base.cpuComponents[keyPath: part], ratio * macDelta,
                accuracy: 1e-9, name)
        }
    }

    // P-B-91: składowe zmieniające się w przeciwne strony nie uśredniają się jednym mnożnikiem (przypadek punktu kontrolnego 8).
    func testComponentsMovingInOppositeDirectionsAreNotAveragedByOneRatio() throws {
        let value = try calibration()
        let moved = DevicePrediction.predict(calibration: value, mac: macFrame(preparation: 0.5, publication: 1.8))
        XCTAssertEqual(moved.cpuMilliseconds, 3.9 / 2 + 1.9882 + 3.1 * 2 + iPhoneRest, accuracy: 1e-9)
        // Jeden mnożnik łączny dałby tu inny wynik.
        let combined = value.ratios.cpu * (0.5 + 0.57 + 1.8 + 0.53)
        XCTAssertGreaterThan(abs(moved.cpuMilliseconds - combined), 0.5)
    }

    // P-B-91: reszta Maca w kalibracji ≤ 0,1 ms nie jest mianownikiem własnego mnożnika, tylko dostaje mnożnik łączny.
    func testRestOfTheMacInTheCalibrationAtMostATenthOfAMillisecondUsesTheCombinedRatio() throws {
        let tight = macFrame(rest: 0.03)  // host_non_gpu 2,5 ms
        let parsed = try DevicePrediction.parse(report: report())
        let value = try DevicePrediction.calibrate(iPhone: parsed, mac: tight, commit: "a367bd0")
        let combined = 9.6007 / 2.5
        XCTAssertEqual(value.ratios.cpu, combined, accuracy: 1e-9)
        let prediction = DevicePrediction.predict(calibration: value, mac: tight)
        XCTAssertEqual(prediction.cpuComponents.waitingMilliseconds, combined * 0.03, accuracy: 1e-9,
            "reszta z mnożnikiem łącznym, nie z ilorazem reszt iPhone'a i Maca")
        XCTAssertEqual(prediction.cpuComponents.preparationMilliseconds, 3.9, accuracy: 1e-9)
        XCTAssertEqual(prediction.cpuComponents.encodingMilliseconds, 1.9882, accuracy: 1e-9)
        XCTAssertEqual(prediction.cpuComponents.publicationMilliseconds, 3.1, accuracy: 1e-9)
        // Przy tej samej kalibracji reszta Maca rośnie: mnożnik zostaje łączny.
        let noisy = DevicePrediction.predict(calibration: value, mac: macFrame(rest: 0.23))
        XCTAssertEqual(noisy.cpuComponents.waitingMilliseconds, combined * 0.23, accuracy: 1e-9)
    }

    // P-B-91: granica 0,1 ms: równe 0,1 to jeszcze mnożnik łączny, ponad 0,1 własny.
    func testTheTenthOfAMillisecondBoundaryOfTheRestSelectsTheRatio() throws {
        let parsed = try DevicePrediction.parse(report: report())
        let atBoundary = try DevicePrediction.calibrate(iPhone: parsed, mac: macFrame(rest: 0.1), commit: "a367bd0")
        let atBoundaryMac = macFrame(rest: 0.1)
        XCTAssertEqual(DevicePrediction.predict(calibration: atBoundary, mac: atBoundaryMac).cpuComponents.waitingMilliseconds,
            atBoundary.ratios.cpu * 0.1, accuracy: 1e-9)
        let above = try DevicePrediction.calibrate(iPhone: parsed, mac: macFrame(rest: 0.11), commit: "a367bd0")
        XCTAssertEqual(DevicePrediction.predict(calibration: above, mac: macFrame(rest: 0.11)).cpuComponents.waitingMilliseconds,
            iPhoneRest, accuracy: 1e-9, "ponad 0,1 ms reszta ma własny mnożnik")
    }

    // P-B-91: szum pomiaru Maca (suma składowych większa od host_non_gpu) nie daje ujemnej reszty ani ujemnej prognozy.
    func testRestOfTheCurrentMacNeverContributesANegativeTime() throws {
        var noisy = mac
        noisy.hostNonGPUMilliseconds = 2.0  // mniej niż suma przygotowania, kodowania i publikacji (2,47 ms)
        let prediction = DevicePrediction.predict(calibration: try calibration(), mac: noisy)
        XCTAssertEqual(prediction.cpuComponents.waitingMilliseconds, 0, accuracy: 1e-12)
        XCTAssertGreaterThan(prediction.cpuMilliseconds, 0)
    }

    // P-B-91: linia `PREDICT_CPU` podaje składowe, a nie zawiera kluczy, które weryfikacje wycinają z linii `PREDICT`.
    func testPredictCPULineListsTheComponentsWithoutTheKeysOfThePredictLine() throws {
        let prediction = DevicePrediction.predict(calibration: try calibration(), mac: mac)
        let line = DevicePrediction.predictCPULine(scene: "acceptance", prediction)
        XCTAssertEqual(line, "PREDICT_CPU iphone-x acceptance: preparation=3.9000 encoding=1.9882 publication=3.1000 waiting=\(DevicePrediction.format(iPhoneRest))")
        XCTAssertFalse(line.contains(" cpu="), line)
        XCTAssertFalse(line.contains(" physics="), line)
        XCTAssertFalse(line.contains(" render="), line)
    }

    // P-B-81: `--check-prediction` kończy się kodem 1 przy błędzie > 10%, 0 przy ≤ 10%.
    func testCheckPredictionPassesAtNinePercentAndFailsAtElevenPercent() throws {
        let nine = try DevicePrediction.check(predictedP95: 21.8, reportedP95: 20)
        XCTAssertEqual(nine.errorFraction, 0.09, accuracy: 1e-9)
        XCTAssertTrue(nine.passed)
        XCTAssertEqual(nine.exitCode, 0)
        XCTAssertTrue(nine.text.hasPrefix("PREDICTION_ERROR p95=20.0000 predicted=21.8000 error=9.0%"), nine.text)
        let eleven = try DevicePrediction.check(predictedP95: 22.2, reportedP95: 20)
        XCTAssertFalse(eleven.passed)
        XCTAssertEqual(eleven.exitCode, 1)
        XCTAssertTrue(eleven.text.hasPrefix("PREDICTION_ERROR p95=20.0000 predicted=22.2000 error=11.0%"), eleven.text)
        // Zaniżona prognoza liczy się tak samo jak zawyżona; błąd ma znak.
        let under = try DevicePrediction.check(predictedP95: 17.8, reportedP95: 20)
        XCTAssertEqual(under.exitCode, 1)
        XCTAssertEqual(under.errorFraction, -0.11, accuracy: 1e-9)
        XCTAssertTrue(under.text.contains("error=-11.0%"), under.text)
        XCTAssertEqual(try DevicePrediction.check(predictedP95: 22.0, reportedP95: 20).exitCode, 0, "10% to jeszcze zgodność")
        XCTAssertEqual(try DevicePrediction.check(predictedP95: 18.0, reportedP95: 20).exitCode, 0)
    }

    func testCheckPredictionRejectsNonPositiveOrNonFiniteReportedTimes() throws {
        XCTAssertEqual(try DevicePrediction.check(predictedP95: 10, reportedP95: 10).exitCode, 0, "poprawne dane nie rzucają")
        for reported in [0.0, -1.0, .nan, .infinity] {
            XCTAssertThrowsError(try DevicePrediction.check(predictedP95: 10, reportedP95: reported), "\(reported)")
        }
        XCTAssertThrowsError(try DevicePrediction.check(predictedP95: .nan, reportedP95: 10))
    }

    func testCheckPredictionAgainstAReportComparesThePredictionToItsP95() throws {
        let value = try calibration()
        let same = try DevicePrediction.checkPrediction(report: report(), calibration: value, mac: mac)
        XCTAssertEqual(same.exitCode, 0)
        XCTAssertEqual(same.predictedMilliseconds, 9.6007 + 14.7964, accuracy: 1e-9)
        XCTAssertEqual(same.reportedMilliseconds, 24.2744, accuracy: 1e-9)
        // p95 z raportu przy prognozie 24,3971 ms: 9% błędu przechodzi, 11% nie.
        let predicted = 9.6007 + 14.7964
        let nine = try DevicePrediction.checkPrediction(report: report(p95: predicted / 1.09), calibration: value, mac: mac)
        XCTAssertEqual(nine.errorFraction, 0.09, accuracy: 1e-3)
        XCTAssertEqual(nine.exitCode, 0)
        let eleven = try DevicePrediction.checkPrediction(report: report(p95: predicted / 1.11), calibration: value, mac: mac)
        XCTAssertEqual(eleven.errorFraction, 0.11, accuracy: 1e-3)
        XCTAssertEqual(eleven.exitCode, 1)
        XCTAssertThrowsError(try DevicePrediction.checkPrediction(report: "p95_ms=20.0", calibration: value, mac: mac))
    }

    // Mediany z przebiegów dla linii STAGES i prognozy: każde pole osobno, odporne na jeden skrajny przebieg.
    func testMedianOfComponentsTakesEachFieldSeparately() {
        func components(_ base: Double) -> StageComponents {
            StageComponents(hostPreparationMilliseconds: base, hostEncodingMilliseconds: base * 2,
                hostWaitingMilliseconds: base * 3, hostPublicationMilliseconds: base * 4,
                hostNonGPUMilliseconds: base * 5, gpuMilliseconds: base * 6, gpuPhysicsMilliseconds: base * 7)
        }
        var odd = components(5)
        odd.hostPreparationMilliseconds = 1  // przebieg z inną kolejnością pól
        let median = StageComponents.median(of: [components(3), components(100), odd, components(1), components(2)])
        XCTAssertEqual(median.hostPreparationMilliseconds, 2, accuracy: 1e-12)
        XCTAssertEqual(median.hostEncodingMilliseconds, 6, accuracy: 1e-12)
        XCTAssertEqual(median.hostWaitingMilliseconds, 9, accuracy: 1e-12)
        XCTAssertEqual(median.hostPublicationMilliseconds, 12, accuracy: 1e-12)
        XCTAssertEqual(median.hostNonGPUMilliseconds, 15, accuracy: 1e-12)
        XCTAssertEqual(median.gpuMilliseconds, 18, accuracy: 1e-12)
        XCTAssertEqual(median.gpuPhysicsMilliseconds, 21, accuracy: 1e-12)
    }

    // Weryfikacje zadań 84–87 wycinają liczby `sed`-em z linii STAGES i PREDICT; format jest częścią kontraktu.
    func testStagesAndPredictLinesCarryTheKeysTheVerifyStepsCut() throws {
        let stages = DevicePrediction.stagesLine(scene: "acceptance", mac: mac)
        XCTAssertEqual(stages, "STAGES acceptance: host_preparation=1.0000 host_encoding=0.5700 host_waiting=1.0000 host_publication=0.9000 host_non_gpu=3.0000 gpu=1.9000 gpu_physics=1.6000")
        let prediction = DevicePrediction.predict(calibration: try calibration(), mac: mac)
        let line = DevicePrediction.predictLine(scene: "acceptance", prediction)
        XCTAssertEqual(line, "PREDICT iphone-x acceptance: p95=24.3971 cpu=9.6007 physics=12.0000 render=2.7964 target=15.00 gate=16.67")
        XCTAssertEqual(DevicePrediction.targetMilliseconds, 15.0)
        XCTAssertEqual(DevicePrediction.gateMilliseconds, 16.67)
    }

    // MARK: - Okablowanie `run` (P-B-79, P-B-81)

    func testScenesToMeasureFollowTheSceneAndPredictionOptions() throws {
        XCTAssertEqual(PerfGuard.scenesToMeasure(try PerfGuardOptions.parse([])), PerfGuard.scenes)
        XCTAssertEqual(PerfGuard.scenesToMeasure(try PerfGuardOptions.parse(["--scene", "acceptance"])), ["acceptance"])
        XCTAssertEqual(PerfGuard.scenesToMeasure(try PerfGuardOptions.parse(["--calibrate", "r.md"])), ["acceptance"])
        XCTAssertEqual(PerfGuard.scenesToMeasure(try PerfGuardOptions.parse(["--check-prediction", "r.md"])), ["acceptance"])
        // Skalowanie 600/300 dotyczy tylko pełnego zestawu.
        XCTAssertTrue(PerfGuard.measuresScaling(try PerfGuardOptions.parse([])))
        XCTAssertFalse(PerfGuard.measuresScaling(try PerfGuardOptions.parse(["--scene", "mixed"])))
        XCTAssertFalse(PerfGuard.measuresScaling(try PerfGuardOptions.parse(["--check-prediction", "r.md"])))
        // Prognoza dotyczy tylko sceny `acceptance`.
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--scene", "mixed", "--calibrate", "r.md"]))
        XCTAssertThrowsError(try PerfGuardOptions.parse(["--check-prediction", "r.md", "--scene", "decals"]))
    }

    func testOnlyTheAcceptanceSceneIsMeasuredInTheNativeResolutionOfTheIPhoneX() throws {
        XCTAssertEqual(PerfGuard.renderSize(for: .acceptance), CGSize(width: 1125, height: 2436))
        for scene: PublicWorldStressBenchmark.Scene in [.stress300, .mixed, .decals] {
            XCTAssertNil(PerfGuard.renderSize(for: scene))
        }
    }

    /// Prawdziwy krótki przebieg `acceptance`: cel renderu 1125×2436 i składowe z raportu bez luk.
    func testAcceptanceMeasurementRendersInNativeResolutionAndReportsAllStages() async throws {
        let gpu = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let report = try await PerfGuard.measureSceneReport(.acceptance, device: gpu, warmupFrames: 2, measuredFrames: 6)
        XCTAssertEqual(report.scene, "acceptance")
        XCTAssertEqual(report.renderWidth, 1125)
        XCTAssertEqual(report.renderHeight, 2436)
        let stages = PerfGuard.components(of: report)
        for value in [stages.hostPreparationMilliseconds, stages.hostEncodingMilliseconds, stages.hostWaitingMilliseconds,
                      stages.hostPublicationMilliseconds, stages.hostNonGPUMilliseconds, stages.gpuMilliseconds,
                      stages.gpuPhysicsMilliseconds] {
            XCTAssertTrue(value.isFinite && value > 0, "\(stages)")
        }
        XCTAssertEqual(stages.hostNonGPUMilliseconds, report.hostNonGPUP95Milliseconds)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString)")
    }

    func testCalibrateOptionWritesTheCalibrationAndPrintsStagesAndPrediction() throws {
        let reportURL = temporaryURL("report.md"), calibrationURL = temporaryURL("calibration.json")
        defer { for url in [reportURL, calibrationURL] { try? FileManager.default.removeItem(at: url) } }
        try report().write(to: reportURL, atomically: true, encoding: .utf8)
        let options = try PerfGuardOptions.parse(["--calibrate", reportURL.path])
        let result = try PerfGuard.predictionLines(options: options, mac: mac, calibrationURL: calibrationURL,
            commit: { "a367bd0567f01d4ccf142691958c53e6249e8d3f" })
        XCTAssertNil(result.exitCode, "kalibracja nie zmienia kodu wyjścia")
        XCTAssertEqual(try DeviceCalibration.load(from: calibrationURL), try calibration())
        XCTAssertEqual(result.lines.count, 4)
        XCTAssertTrue(result.lines[0].hasPrefix("STAGES acceptance:"))
        XCTAssertTrue(result.lines[2].hasPrefix("PREDICT iphone-x acceptance:"))
        XCTAssertTrue(result.lines[3].hasPrefix("PREDICT_CPU iphone-x acceptance: preparation="), "składowe CPU po linii PREDICT")
        // Raport z innego commitu niż bieżący nie jest zapisywany jako kalibracja.
        let other = temporaryURL("other.json")
        XCTAssertThrowsError(try PerfGuard.predictionLines(options: options, mac: mac, calibrationURL: other,
            commit: { "0000000000000000000000000000000000000000" }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testPredictLineAppearsWheneverTheCalibrationFileExistsAndDoesNotChangeTheExitCode() throws {
        let calibrationURL = temporaryURL("calibration.json")
        defer { try? FileManager.default.removeItem(at: calibrationURL) }
        let none = try PerfGuard.predictionLines(options: PerfGuardOptions(), mac: mac, calibrationURL: calibrationURL,
            commit: { "abc" })
        XCTAssertEqual(none.lines.count, 1, "bez pliku kalibracji jest tylko STAGES")
        try calibration().write(to: calibrationURL)
        let with = try PerfGuard.predictionLines(options: PerfGuardOptions(), mac: mac, calibrationURL: calibrationURL,
            commit: { "abc" })
        XCTAssertEqual(with.lines.count, 3, "STAGES, PREDICT i PREDICT_CPU")
        XCTAssertTrue(with.lines[2].hasPrefix("PREDICT_CPU iphone-x acceptance: preparation="))
        XCTAssertNil(with.exitCode)
    }

    func testCheckPredictionOptionSetsTheExitCodeFromTheError() throws {
        let reportURL = temporaryURL("checkpoint.md"), calibrationURL = temporaryURL("calibration.json")
        defer { for url in [reportURL, calibrationURL] { try? FileManager.default.removeItem(at: url) } }
        try calibration().write(to: calibrationURL)
        let options = try PerfGuardOptions.parse(["--check-prediction", reportURL.path])
        let predicted = 9.6007 + 14.7964
        try report(p95: predicted / 1.09).write(to: reportURL, atomically: true, encoding: .utf8)
        let near = try PerfGuard.predictionLines(options: options, mac: mac, calibrationURL: calibrationURL, commit: { "a" })
        XCTAssertEqual(near.exitCode, 0)
        XCTAssertTrue(try XCTUnwrap(near.lines.last).hasPrefix("PREDICTION_ERROR p95="))
        try report(p95: predicted / 1.11).write(to: reportURL, atomically: true, encoding: .utf8)
        let far = try PerfGuard.predictionLines(options: options, mac: mac, calibrationURL: calibrationURL, commit: { "a" })
        XCTAssertEqual(far.exitCode, 1)
        // Bez pliku kalibracji nie ma z czym porównać.
        XCTAssertThrowsError(try PerfGuard.predictionLines(options: options, mac: mac,
            calibrationURL: temporaryURL("missing.json"), commit: { "a" }))
    }

    func testExitCodeFailsWhenEitherTheRegressionOrThePredictionFails() {
        XCTAssertEqual(PerfGuard.combinedExitCode(regression: 1, prediction: 0), 1, "poprawna prognoza nie kasuje regresji")
        XCTAssertEqual(PerfGuard.combinedExitCode(regression: 0, prediction: 1), 1)
        XCTAssertEqual(PerfGuard.combinedExitCode(regression: 0, prediction: 0), 0)
        XCTAssertEqual(PerfGuard.combinedExitCode(regression: 1, prediction: 1), 1)
        XCTAssertEqual(PerfGuard.combinedExitCode(regression: 0, prediction: nil), 0)
        XCTAssertEqual(PerfGuard.combinedExitCode(regression: 1, prediction: nil), 1)
    }
}
