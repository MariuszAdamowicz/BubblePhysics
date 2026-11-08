import XCTest
import Metal
@testable import BubblePhysicsNativeMetal

@MainActor
final class NativeMetalResourceReuseTests: XCTestCase {
    func testCopyRunsMergeOnlyIndicesAdvancingTogether() {
        let runs = NativeMetalCopyRun.coalesce([(0, 0), (1, 1), (2, 2), (5, 5), (6, 7), (7, 8), (9, 3)])
        XCTAssertEqual(runs, [
            NativeMetalCopyRun(source: 0, destination: 0, count: 3),
            NativeMetalCopyRun(source: 5, destination: 5, count: 1),
            NativeMetalCopyRun(source: 6, destination: 7, count: 2),
            NativeMetalCopyRun(source: 9, destination: 3, count: 1)
        ])
        XCTAssertTrue(NativeMetalCopyRun.coalesce([]).isEmpty)
    }

    func testReusableBufferGrowsOnlyWhenCapacityIsExceeded() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let reusable = NativeMetalReusableBuffer()
        let first = try reusable.upload([UInt32](repeating: 7, count: 8), device: device)
        let second = try reusable.upload([UInt32](repeating: 9, count: 4), device: device)
        XCTAssertTrue(first === second)
        XCTAssertEqual(second.contents().load(as: UInt32.self), 9)
        let grown = try reusable.upload([UInt32](repeating: 1, count: 100), device: device)
        XCTAssertFalse(grown === first)
        XCTAssertGreaterThanOrEqual(grown.length, 400)
    }

    func testAlternatingBufferNeverReturnsThePreviousBufferAndZeroesIt() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let alternating = NativeMetalAlternatingBuffer()
        let first = try alternating.next(avoiding: nil, zeroedCount: 4, of: UInt64.self, device: device)
        first.contents().storeBytes(of: UInt64.max, as: UInt64.self)
        let second = try alternating.next(avoiding: first, zeroedCount: 4, of: UInt64.self, device: device)
        XCTAssertFalse(first === second)
        XCTAssertEqual(first.contents().load(as: UInt64.self), UInt64.max)
        let third = try alternating.next(avoiding: second, zeroedCount: 4, of: UInt64.self, device: device)
        XCTAssertTrue(third === first)
        XCTAssertEqual(third.contents().load(as: UInt64.self), 0)
    }

    func testSolverPipelinesAreCompiledOncePerDevice() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let first = try NativeMetalPipelineCache.pipelines(for: device)
        let second = try NativeMetalPipelineCache.pipelines(for: device)
        XCTAssertTrue(first.predict === second.predict)
        XCTAssertEqual(Set(first.stages.keys), Set(NativeMetalPipelineCache.stageNames))
    }
}
