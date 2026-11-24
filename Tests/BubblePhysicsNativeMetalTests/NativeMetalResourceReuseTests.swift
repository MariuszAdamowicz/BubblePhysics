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
        XCTAssertEqual(Set(first.stages.keys), Set(NativeMetalPipelineCache.stageNames))
    }

    /// Wycinki leżą w jednym buforze, każdy od przesunięcia wyrównanego do 256 B, bez nakładania i w granicach bufora.
    private func assertDisjointAlignedSlices(_ slices: [NativeMetalBufferSlice], in buffer: MTLBuffer,
                                             file: StaticString = #filePath, line: UInt = #line) {
        for slice in slices {
            XCTAssertTrue(slice.buffer === buffer, "wycinek poza wspólnym buforem", file: file, line: line)
            XCTAssertEqual(slice.offset % NativeMetalBufferSlice.alignment, 0, "przesunięcie \(slice.offset)", file: file, line: line)
            XCTAssertEqual(slice.contents(), buffer.contents().advanced(by: slice.offset), file: file, line: line)
        }
        let sorted = slices.sorted { $0.offset < $1.offset }
        for (previous, next) in zip(sorted, sorted.dropFirst()) {
            XCTAssertLessThanOrEqual(previous.offset + previous.length, next.offset, "wycinki nachodzą na siebie", file: file, line: line)
        }
        if let last = sorted.last { XCTAssertLessThanOrEqual(last.offset + last.length, buffer.length, file: file, line: line) }
    }

    /// Bugfix iPhone X (BF-D-2): siedem małych buforów sterowania kroku to jeden `MTLBuffer`, więc jądro jednej grupy wiąże je
    /// jednym slotem; każdy wycinek ma dawną długość.
    func testStepControlBlockSharesOneBufferWithAlignedSlices() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let state = try NativeMetalPersistentState(device: device, bubbleCount: 4, segmentCount: 0)
        let slices = [state.contactControl, state.dispatchStatistics, state.candidateOverflow, state.substepControl,
                      state.substepDispatch, state.substepSteps, state.contactAssertion]
        assertDisjointAlignedSlices(slices, in: state.stepControl)
        XCTAssertEqual(slices.map(\.length), [MemoryLayout<NativeMetalContactControl>.stride, 3 * MemoryLayout<SIMD4<UInt32>>.stride,
            MemoryLayout<SIMD4<UInt32>>.stride, MemoryLayout<NativeMetalSubstepControl>.stride, 3 * MemoryLayout<UInt32>.stride,
            NativeMetalSubstep.frameLimit * MemoryLayout<Float>.stride, MemoryLayout<NativeMetalContactAssertion>.stride])
    }

    /// Bugfix iPhone X (BF-D-2): sześć buforów rekordów sił to jeden `MTLBuffer` wgrywany jednym `upload`; każdy wycinek niesie
    /// swoje rekordy, a pusta tablica (tu motory) zajmuje jeden rekord, jak dawny osobny bufor.
    func testForceRecordsShareOneBufferWithAlignedSlices() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var input = NativeForceInput()
        input.globalForce = SIMD2(1, -2)
        input.fields = [NativeMetalForceField(identity: SIMD2(7, 0), pose: SIMD4(1, 2, 0, 0), strength: SIMD4(3, 4, 0, 50),
                                              shape: .zero, filter: .zero),
                        NativeMetalForceField(identity: SIMD2(9, 0), pose: SIMD4(5, 6, 0, 1), strength: SIMD4(0, 0, 8, 20),
                                              shape: SIMD4(NativeMetalForceField.radialKind, 0, 3, 0), filter: SIMD4(0, 2, 1, 0))]
        input.fieldVertices = [SIMD2(0, 0), SIMD2(1, 0), SIMD2(0, 1)]
        input.fieldObjectIDs = [3, 5]
        input.bandDrives = [NativeMetalBandDrive(identity: SIMD2(3, 0), band: SIMD4(10, 20, 100, 0))]
        let forces = NativeMetalForceBuffers()
        try forces.upload(input, device: device)
        let slices = try [forces.control, forces.fields, forces.fieldVertices, forces.fieldObjectIDs, forces.bands, forces.motors]
            .map { try XCTUnwrap($0) }
        assertDisjointAlignedSlices(slices, in: try XCTUnwrap(forces.records))
        XCTAssertEqual(slices.map(\.length), [MemoryLayout<NativeMetalForceControl>.stride, 2 * MemoryLayout<NativeMetalForceField>.stride,
            3 * MemoryLayout<SIMD2<Float>>.stride, 2 * MemoryLayout<UInt64>.stride, MemoryLayout<NativeMetalBandDrive>.stride,
            MemoryLayout<NativeMetalMotor>.stride])
        let control = slices[0].contents().load(as: NativeMetalForceControl.self)
        XCTAssertEqual(control.global, SIMD4(1, -2, 0, 0))
        XCTAssertEqual(control.counts, SIMD4(2, 1, 0, 0))
        XCTAssertEqual(slices[1].contents().load(fromByteOffset: MemoryLayout<NativeMetalForceField>.stride, as: NativeMetalForceField.self),
                       input.fields[1])
        XCTAssertEqual(slices[2].contents().load(fromByteOffset: 16, as: SIMD2<Float>.self), SIMD2(0, 1))
        XCTAssertEqual(slices[3].contents().load(fromByteOffset: 8, as: UInt64.self), 5)
        XCTAssertEqual(slices[4].contents().load(as: NativeMetalBandDrive.self), input.bandDrives[0])
    }
}
