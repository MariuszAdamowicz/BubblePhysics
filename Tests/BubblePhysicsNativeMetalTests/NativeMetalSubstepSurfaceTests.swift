import BubblePhysicsNativeMetal
import XCTest

/// Powierzchnia silnika 4.0.0 bez działania (plan, zadanie 4): przełączniki pakietowe `NativeMetalConfiguration`, pola
/// telemetrii podkroków i szczegóły awarii. Tu tylko kształt i wartości domyślne; zachowanie dodają kolejne zadania.
final class NativeMetalSubstepSurfaceTests: XCTestCase {
    // G4-AC3, G5-AC3, G6-AC2: domyślnie żaden przełącznik testowy nie zmienia silnika.
    func testSubstepSwitchesAreOffByDefault() {
        let configuration = NativeMetalConfiguration.default
        XCTAssertEqual(configuration.substepSplitMultiplier, 1)
        XCTAssertFalse(configuration.minimumMarginOnly)
        XCTAssertFalse(configuration.captureSubsteps)
        XCTAssertFalse(configuration.assertEverySubstep)
        XCTAssertNil(configuration.injectedSubstepState)
        // G8-AC4: przełączniki ścieżek wykonania są domyślnie wyłączone; kubełki siatki w grupie mają 2048, limit kandydatów to pojemność 128.
        XCTAssertFalse(configuration.forceMultipleDispatches)
        XCTAssertEqual(configuration.candidateLimitPerObject, 128)
        XCTAssertEqual(configuration.gridHashBucketCount, 2048)
    }

    /// P-B-40: przełączniki ścieżek wykonania przechodzą przez `sanitized`, a limit kandydatów i liczba kubełków mają dopuszczalny zakres.
    func testSanitizedKeepsExecutionPathSwitchesAndClampsTheirRanges() {
        var configuration = NativeMetalConfiguration.default
        configuration.forceMultipleDispatches = true
        configuration.candidateLimitPerObject = 8
        configuration.gridHashBucketCount = 1
        let kept = configuration.sanitized
        XCTAssertTrue(kept.forceMultipleDispatches)
        XCTAssertEqual(kept.candidateLimitPerObject, 8)
        XCTAssertEqual(kept.gridHashBucketCount, 1, "1 kubełek wymusza kolizję każdej komórki (P-B-46)")
        for (invalid, expected) in [(0, 1), (-5, 1), (129, 128), (100_000, 128)] {
            configuration.candidateLimitPerObject = invalid
            XCTAssertEqual(configuration.sanitized.candidateLimitPerObject, expected, "limit kandydatów \(invalid): najwyżej pojemność 128")
        }
        for invalid in [0, -1] {
            configuration.gridHashBucketCount = invalid
            XCTAssertEqual(configuration.sanitized.gridHashBucketCount, 1, "kubełki \(invalid)")
        }
        // Kubełki siatki leżą w 8 KB pamięci grupy jądra jednej grupy, więc więcej niż 2048 nie mieści się.
        configuration.gridHashBucketCount = 100_000
        XCTAssertEqual(configuration.sanitized.gridHashBucketCount, 2048, "kubełki ponad pojemność pamięci grupy")
    }

    func testSanitizedKeepsSwitchesAndClampsSplitMultiplier() {
        var configuration = NativeMetalConfiguration.default
        configuration.substepSplitMultiplier = 4
        configuration.minimumMarginOnly = true
        configuration.captureSubsteps = true
        configuration.assertEverySubstep = true
        configuration.injectedSubstepState = NativeMetalInjectedSubstepState(
            afterSubstep: 2, objectID: 5, position: [1, 2])
        let kept = configuration.sanitized
        XCTAssertEqual(kept.substepSplitMultiplier, 4)
        XCTAssertTrue(kept.minimumMarginOnly)
        XCTAssertTrue(kept.captureSubsteps)
        XCTAssertTrue(kept.assertEverySubstep)
        XCTAssertEqual(kept.injectedSubstepState,
                       NativeMetalInjectedSubstepState(afterSubstep: 2, objectID: 5, position: [1, 2]))
        for invalid in [0, -3] {
            configuration.substepSplitMultiplier = invalid
            XCTAssertEqual(configuration.sanitized.substepSplitMultiplier, 1, "mnożnik \(invalid)")
        }
    }

    // G8-AC1: podkroki, przebudowy siatki oraz czas GPU fizyki i konturu są osobnymi polami.
    func testTelemetryCarriesSubstepFieldsSeparately() {
        let empty = NativeMetalFrameTelemetry()
        XCTAssertEqual(empty.substepCount, 0)
        XCTAssertEqual(empty.gridRebuildCount, 0)
        XCTAssertEqual(empty.physicsGPUMilliseconds, 0)
        XCTAssertEqual(empty.contourGPUMilliseconds, 0)
        let filled = NativeMetalFrameTelemetry(backend: .nativeMetal, gpuMilliseconds: 3, substepCount: 7,
                                               gridRebuildCount: 2, physicsGPUMilliseconds: 1.5,
                                               contourGPUMilliseconds: 0.75)
        XCTAssertEqual(filled.substepCount, 7)
        XCTAssertEqual(filled.gridRebuildCount, 2)
        XCTAssertEqual(filled.physicsGPUMilliseconds, 1.5)
        XCTAssertEqual(filled.contourGPUMilliseconds, 0.75)
        XCTAssertEqual(filled.gpuMilliseconds, 3)
    }

    // P-B-40: telemetria niesie osobno bufory podkroków, ścieżkę i szerokość grupy; zero i ścieżka wielu dyspozycji to wartości domyślne.
    func testTelemetryCarriesExecutionPathFields() {
        let empty = NativeMetalFrameTelemetry()
        XCTAssertEqual(empty.substepBufferCount, 0)
        XCTAssertEqual(empty.executionPath, .multipleDispatches)
        XCTAssertEqual(empty.singleGroupWidth, 0)
        let filled = NativeMetalFrameTelemetry(backend: .nativeMetal, substepCount: 30, gridRebuildCount: 2, substepBufferCount: 1,
                                               executionPath: .singleDispatch, singleGroupWidth: 1024)
        XCTAssertEqual(filled.substepBufferCount, 1)
        XCTAssertEqual(filled.executionPath, .singleDispatch)
        XCTAssertEqual(filled.singleGroupWidth, 1024)
        XCTAssertEqual(NativeMetalExecutionPath.singleDispatch.rawValue, "singleDispatch")
        XCTAssertEqual(NativeMetalExecutionPath.multipleDispatches.rawValue, "multipleDispatches")
    }

    // P-B-40: `gridRebuildCount` to przebudowy wymuszone zapasem, a pary buforów liczy osobne `substepBufferCount`; osobnego licznika przebudów
    // zapasu nie ma (zadanie 30), więc telemetria ma dokładnie te pola.
    func testTelemetryHasOneRebuildFieldAndNoSeparateMarginCounter() {
        let labels = Set(Mirror(reflecting: NativeMetalFrameTelemetry()).children.compactMap(\.label))
        XCTAssertEqual(labels, ["backend", "commandBufferCount", "encoderCount", "contactCount", "didEncounterNonFinite", "fallbackReason",
                                "gpuMilliseconds", "substepCount", "gridRebuildCount", "substepBufferCount", "executionPath",
                                "singleGroupWidth", "physicsGPUMilliseconds", "contourGPUMilliseconds", "candidatePairCount"])
    }

    // G6-AC2, G6-AC5: awaria silnika niesie obiekty, krawędź, odległość i człon h.
    func testSafetyFailureCarriesDetail() {
        let detail = NativeMetalFailureDetail(objectIDs: [3, 8], edgeIndex: 1, distance: -2, limitingTerm: .distance)
        let failure = NativeMetalSafetyFailure(reason: .contactViolation, telemetry: NativeMetalFrameTelemetry(),
                                               profile: NativeMetalFrameProfile(), detail: detail)
        XCTAssertEqual(failure.detail, detail)
        XCTAssertEqual(detail.objectIDs, [3, 8])
        XCTAssertEqual(detail.edgeIndex, 1)
        XCTAssertEqual(detail.distance, -2)
        XCTAssertEqual(detail.limitingTerm, .distance)
        let limit = NativeMetalSafetyFailure(reason: .substepLimitExceeded, telemetry: NativeMetalFrameTelemetry(),
                                             profile: NativeMetalFrameProfile())
        XCTAssertNil(limit.detail)
        XCTAssertNil(limit.guardCause)
    }
}
