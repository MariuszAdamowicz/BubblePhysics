@testable import BubblePhysicsNativeMetal
import XCTest

/// Bugfix iPhone X (BF-D-3, review): jedna dyspozycja wymaga pamięci grupy na tablicę współdzieloną `singleGroupMemoryLength`
/// plus pamięć statyczną potoku. Granica dokładnie: równość wystarcza, bajt mniej już nie.
final class NativeMetalSingleDispatchSupportTests: XCTestCase {
    private let staticLength = 512

    func testExactlyEnoughThreadgroupMemorySupportsSingleDispatch() {
        let required = NativeMetalSubstep.singleGroupMemoryLength + staticLength
        XCTAssertTrue(NativeMetalSolver.supportsSingleDispatch(maxThreadgroupMemoryLength: required,
                                                               staticThreadgroupMemoryLength: staticLength))
    }

    func testOneByteTooLittleThreadgroupMemoryDoesNotSupportSingleDispatch() {
        let required = NativeMetalSubstep.singleGroupMemoryLength + staticLength
        XCTAssertFalse(NativeMetalSolver.supportsSingleDispatch(maxThreadgroupMemoryLength: required - 1,
                                                                staticThreadgroupMemoryLength: staticLength))
    }

    /// Pamięć statyczna potoku liczy się do wymagania: bez niej ta sama pamięć urządzenia by wystarczyła.
    func testStaticThreadgroupMemoryOfThePipelineCountsTowardsTheRequirement() {
        let length = NativeMetalSubstep.singleGroupMemoryLength
        XCTAssertTrue(NativeMetalSolver.supportsSingleDispatch(maxThreadgroupMemoryLength: length, staticThreadgroupMemoryLength: 0))
        XCTAssertFalse(NativeMetalSolver.supportsSingleDispatch(maxThreadgroupMemoryLength: length, staticThreadgroupMemoryLength: 1))
    }
}
