@testable import BubblePhysics
import BubblePhysicsNativeMetal
import Metal
import XCTest

/// Szew testów świata silnika 4.0.0 (plan, zadanie 4): `makeBenchmarkWorld(configuration:device:native:)` przekazuje
/// konfigurację natywną do solvera, a bez niej daje konfigurację domyślną.
@MainActor
final class SubstepSeamTests: XCTestCase {
    private func device() throws -> MTLDevice {
        try XCTUnwrap(MTLCreateSystemDefaultDevice(), "brak urządzenia Metal")
    }

    func testNativeConfigurationReachesTheSolver() throws {
        let device = try device()
        var native = NativeMetalConfiguration.default
        native.substepSplitMultiplier = 4
        native.minimumMarginOnly = true
        native.captureSubsteps = true
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: CrowdScene.configuration(), device: device,
                                                       native: native)
        let applied = try XCTUnwrap(world.benchmarkNativeConfiguration)
        XCTAssertEqual(applied.substepSplitMultiplier, 4)
        XCTAssertTrue(applied.minimumMarginOnly)
        XCTAssertTrue(applied.captureSubsteps)
        XCTAssertFalse(applied.assertEverySubstep)
    }

    func testDefaultNativeConfigurationHasAllSwitchesOff() throws {
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: CrowdScene.configuration(), device: device())
        let applied = try XCTUnwrap(world.benchmarkNativeConfiguration)
        XCTAssertEqual(applied.substepSplitMultiplier, 1)
        XCTAssertFalse(applied.minimumMarginOnly)
        XCTAssertFalse(applied.captureSubsteps)
        XCTAssertFalse(applied.assertEverySubstep)
        XCTAssertNil(applied.injectedSubstepState)
    }

    // P-B-40: przełączniki ścieżek wykonania dochodzą do solvera.
    func testExecutionPathSwitchesReachTheSolver() throws {
        var native = NativeMetalConfiguration.default
        native.forceMultipleDispatches = true
        native.candidateLimitPerObject = 8
        native.gridHashBucketCount = 1
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: CrowdScene.configuration(), device: device(), native: native)
        let applied = try XCTUnwrap(world.benchmarkNativeConfiguration)
        XCTAssertTrue(applied.forceMultipleDispatches)
        XCTAssertEqual(applied.candidateLimitPerObject, 8)
        XCTAssertEqual(applied.gridHashBucketCount, 1)
        let defaults = try XCTUnwrap(BubbleWorld.makeBenchmarkWorld(configuration: CrowdScene.configuration(), device: device())
            .benchmarkNativeConfiguration)
        XCTAssertFalse(defaults.forceMultipleDispatches)
        XCTAssertEqual(defaults.candidateLimitPerObject, 128)
        XCTAssertEqual(defaults.gridHashBucketCount, 2048)
    }

    /// P-B-40: świat do 1024 baniek liczy się jedną dyspozycją (1 bufor podkroków, szerokość grupy z potoku), a `forceMultipleDispatches`
    /// wymusza pary buforów w tym samym świecie (szerokość 0, po jednej parze na dwa command buffery klatki).
    func testTheSwitchChoosesTheExecutionPathReportedInTelemetry() async throws {
        for forced in [false, true] {
            var native = NativeMetalConfiguration.default
            native.forceMultipleDispatches = forced
            let world = try ForceScene.makeWorld(native: native) {
                try $0.add(ForceScene.bubble(1, at: .zero, velocity: [30, 0]))
            }
            let recorded = try await ForceScene.run(world, frames: 5)
            ForceScene.assertHealthy(world)
            XCTAssertEqual(recorded.count, 5)
            for item in recorded {
                let telemetry = try XCTUnwrap(item.telemetry, "forced=\(forced) krok \(item.step): brak telemetrii")
                guard ForceScene.check(telemetry.executionPath == (forced ? .multipleDispatches : .singleDispatch),
                                       "forced=\(forced) krok \(item.step): ścieżka \(telemetry.executionPath)") else { return }
                if forced {
                    guard ForceScene.check(telemetry.singleGroupWidth == 0, "krok \(item.step): szerokość \(telemetry.singleGroupWidth) w wielu dyspozycjach"),
                          ForceScene.check(telemetry.substepBufferCount >= 1 && telemetry.commandBufferCount == 2 * telemetry.substepBufferCount,
                                           "krok \(item.step): \(telemetry.substepBufferCount) par, \(telemetry.commandBufferCount) command bufferów")
                    else { return }
                } else {
                    guard ForceScene.check(telemetry.substepBufferCount == 1, "krok \(item.step): \(telemetry.substepBufferCount) buforów podkroków"),
                          ForceScene.check((1...1024).contains(telemetry.singleGroupWidth), "krok \(item.step): szerokość grupy \(telemetry.singleGroupWidth)")
                    else { return }
                }
            }
        }
    }

    /// P-B-40: `candidateLimitPerObject` skraca wiersz kandydatów. Środkowa bańka siatki 3 × 3 (r 24, odstęp 50) ma 4 kandydatów
    /// w zapasie obwiedni; limit 2 odrzuca część z nich i liczy przepełnienie, a limit domyślny 128 nie.
    func testCandidateLimitShortensTheCandidateRow() async throws {
        func overflow(limit: Int?) async throws -> (overflow: Int, maximum: Int) {
            var native = NativeMetalConfiguration.default
            if let limit { native.candidateLimitPerObject = limit }
            let world = try ForceScene.makeWorld(native: native) { setup in
                var transaction = setup
                for row in 0..<3 {
                    for column in 0..<3 {
                        transaction = try transaction.add(ForceScene.bubble(UInt64(1 + 3 * row + column),
                                                                            at: [Float(column - 1) * 50, Float(row - 1) * 50]))
                    }
                }
                return transaction
            }
            _ = try await ForceScene.run(world, frames: 3)
            return (world.diagnostics.contactCandidateOverflow, world.diagnostics.maximumContactCandidatesPerObject)
        }
        let full = try await overflow(limit: nil)
        XCTAssertEqual(full.overflow, 0, "limit 128 mieści wszystkich kandydatów")
        XCTAssertGreaterThanOrEqual(full.maximum, 4, "środkowa bańka ma 4 kandydatów w zapasie obwiedni")
        let limited = try await overflow(limit: 2)
        XCTAssertGreaterThan(limited.overflow, 0, "limit 2 odrzuca kandydatów środkowej bańki")
    }
}
