import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalVisualReplayTests: XCTestCase {
    func testReplayUsesIdenticalScriptedInputAndReportsFiniteCPUAndGPUMetrics() async throws {
        try XCTSkipUnless(MTLCreateSystemDefaultDevice() != nil, "Metal jest wymagany dla replayu diagnostycznego")

        for solverIterationCount in [4, 8, 16] {
            for (density, expectedBubbleCount) in [(ReferenceVisualDensity.six, 6), (.twentyFour, 24)] {
                let report = try await NativeMetalVisualReplay.compare(
                    density: density, frameCount: 24, solverIterationCount: solverIterationCount
                )
                print("visual_replay iterations=\(solverIterationCount) density=\(expectedBubbleCount) center_p95=\(report.centerDifferenceP95) contour_p95=\(report.contourRadialDifferenceP95) cpu_contour_step_max=\(report.cpuContourStepMaximum) gpu_contour_step_max=\(report.gpuContourStepMaximum) contact_count_difference_mean=\(report.contactCountDifferenceMean)")

                XCTAssertEqual(report.frames.count, 24)
                XCTAssertTrue(report.frames.allSatisfy { $0.gpuBackend == .nativeMetal })
                XCTAssertTrue(report.frames.allSatisfy { $0.cpuBubbleCount == expectedBubbleCount && $0.gpuBubbleCount == expectedBubbleCount })
                XCTAssertTrue(report.centerDifferenceP95.isFinite)
                XCTAssertTrue(report.contourRadialDifferenceP95.isFinite)
                XCTAssertTrue(report.cpuContourStepMaximum.isFinite)
                XCTAssertTrue(report.gpuContourStepMaximum.isFinite)
                XCTAssertTrue(report.contactCountDifferenceMean.isFinite)
            }
        }
    }
}
