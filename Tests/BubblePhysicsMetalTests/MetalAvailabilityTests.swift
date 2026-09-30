import XCTest
@testable import BubblePhysicsMetal

final class MetalAvailabilityTests: XCTestCase {
    func testMetalSolverLoadsRequiredComputeFunctionsWhenMetalIsAvailable() throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }

        XCTAssertTrue(solver.isAvailable)
        XCTAssertTrue(solver.loadedFunctionNames.contains("predictParticles"))
#if os(iOS)
        XCTAssertEqual(solver.shaderLibraryOrigin, .compiledBundle)
#else
        XCTAssertEqual(solver.shaderLibraryOrigin, .runtimeSource)
#endif
    }
}
