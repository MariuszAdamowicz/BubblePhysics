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
