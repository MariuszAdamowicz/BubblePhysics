import XCTest
@testable import BubblePhysicsReference

final class ReferencePCGSolverTests: XCTestCase {
    func testSolvesLiteralSPDSystem() {
        let result = ReferencePCGSolver.solve(
            rightHandSide: [.init(x: 1, y: 2)],
            apply: { input in [.init(x: 4 * input[0].x + input[0].y, y: input[0].x + 3 * input[0].y)] },
            inverseDiagonal: [.init(x: 0.25, y: 1.0 / 3.0)],
            tolerance: 0.000001,
            iterationLimit: 8
        )
        XCTAssertEqual(result.solution[0].x, 1.0 / 11.0, accuracy: 0.00001)
        XCTAssertEqual(result.solution[0].y, 7.0 / 11.0, accuracy: 0.00001)
        XCTAssertFalse(result.hasNonFiniteState)
    }

    func testZeroRightHandSideStopsWithoutIteration() {
        let result = ReferencePCGSolver.solve(
            rightHandSide: [.zero], apply: { $0 }, inverseDiagonal: [.init(x: 1, y: 1)],
            tolerance: 0.001, iterationLimit: 24
        )
        XCTAssertEqual(result.iterationCount, 0)
        XCTAssertEqual(result.initialResidualNorm, 0)
        XCTAssertEqual(result.finalResidualNorm, 0)
    }

    func testIterationLimitBoundsWorkAndReturnsFinitePartialSolution() {
        let result = ReferencePCGSolver.solve(
            rightHandSide: [.init(x: 1, y: 2)],
            apply: { input in [.init(x: 4 * input[0].x + input[0].y, y: input[0].x + 3 * input[0].y)] },
            inverseDiagonal: [.init(x: 0.25, y: 1.0 / 3.0)],
            tolerance: 0,
            iterationLimit: 1
        )

        XCTAssertEqual(result.iterationCount, 1)
        XCTAssertTrue(result.solution[0].isFinite)
        XCTAssertFalse(result.hasNonFiniteState)
    }
}
