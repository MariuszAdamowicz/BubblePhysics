import XCTest
@testable import BubblePhysicsMetal

final class MetalAvailabilityTests: XCTestCase {
    func testMetalSolverLoadsRequiredComputeFunctionsWhenMetalIsAvailable() throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }

        XCTAssertTrue(solver.isAvailable)
        XCTAssertTrue(solver.loadedFunctionNames.contains("predictParticles"))
    }
}
