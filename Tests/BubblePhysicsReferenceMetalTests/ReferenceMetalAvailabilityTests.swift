import XCTest
import Metal
@testable import BubblePhysicsReferenceMetal

final class ReferenceMetalAvailabilityTests: XCTestCase {
    // A missing shader or failed pipeline must fail on hosts with Metal.
    func testReferenceMetalSolverLoadsRequiredPipelines() throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw XCTSkip("Metal unavailable")
        }
        let solver = try XCTUnwrap(ReferenceMetalSolver(device: device))
        XCTAssertTrue(solver.loadedFunctionNames.contains("referenceBuildResidual"))
    }

    // Empty frames must not introduce NaN through telemetry defaults.
    func testEmptyTelemetryIsFinite() {
        let telemetry = ReferenceMetalFrameTelemetry()
        XCTAssertTrue(telemetry.frameMilliseconds.isFinite)
        XCTAssertTrue(telemetry.gpuMilliseconds.isFinite)
        XCTAssertTrue(telemetry.finalResidual.isFinite)
        XCTAssertEqual(telemetry.frameMilliseconds, 0)
        XCTAssertEqual(telemetry.gpuMilliseconds, 0)
        XCTAssertEqual(telemetry.finalResidual, 0)
        XCTAssertEqual(telemetry.newtonIterations, 0)
        XCTAssertEqual(telemetry.pcgIterations, 0)
        XCTAssertFalse(telemetry.didOverflow)
        XCTAssertFalse(telemetry.didEncounterNonFinite)
        XCTAssertNil(telemetry.fallbackReason)
        XCTAssertEqual(telemetry.backend, .cpu)
    }
}
