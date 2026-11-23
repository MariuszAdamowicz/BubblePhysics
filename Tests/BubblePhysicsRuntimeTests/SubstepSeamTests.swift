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
}
