import XCTest
import Metal
@testable import BubblePhysicsNativeMetal

/// Kernele skrócone w etapie 9 (zadanie 93) dają ten sam wynik co dawna sieć dispatchy, bit w bit.
@MainActor
final class NativeMetalChainKernelTests: XCTestCase {
    private struct Generator {
        var state: UInt64
        mutating func next() -> UInt32 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: state >> 33)
        }
        mutating func unit() -> Float { Float(next() % 100_000) / 100_000 }
    }

    private func makeBuffer<T>(_ values: [T], device: MTLDevice) throws -> MTLBuffer {
        try XCTUnwrap(values.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) })
    }

    private func run(device: MTLDevice, _ body: (MTLComputeCommandEncoder) -> Int) throws -> Int {
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        let dispatches = body(encoder)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        return dispatches
    }

    // MARK: sortowanie siatki

    private func gridLess(_ a: NativeMetalGridEntry, _ b: NativeMetalGridEntry) -> Bool {
        if a.metadata.y != b.metadata.y { return a.metadata.y > b.metadata.y }
        if a.cell.x != b.cell.x { return a.cell.x < b.cell.x }
        if a.cell.y != b.cell.y { return a.cell.y < b.cell.y }
        return a.metadata.x < b.metadata.x
    }

    func testChunkedGridSortMatchesTheTotalOrderForEveryCapacity() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        for capacity in [16, 32, 64, 128, 256, 512, 1024, 4096] {
            var generator = Generator(state: UInt64(capacity) &* 7919)
            // Mało komórek i wiele nieprawidłowych wpisów: remisy rozstrzyga indeks.
            let entries: [NativeMetalGridEntry] = (0..<capacity).map { index in
                let valid = generator.next() % 5 != 0
                let cell = valid ? SIMD2<Int64>(Int64(generator.next() % 7) - 3, Int64(generator.next() % 5) - 2) : .zero
                return NativeMetalGridEntry(cell: cell, metadata: SIMD4(UInt32(index), valid ? 1 : 0, 0, 0))
            }
            let expected = entries.sorted(by: gridLess)
            let grid = try makeBuffer(entries, device: device)
            let dispatches = try run(device: device) {
                NativeMetalGridSort.encode($0, pipelines: pipelines, grid: grid, capacity: capacity)
            }
            let result = Array(UnsafeBufferPointer(start: grid.contents().bindMemory(to: NativeMetalGridEntry.self, capacity: capacity),
                                                   count: capacity))
            XCTAssertEqual(result.map(\.metadata.x), expected.map(\.metadata.x), "capacity \(capacity)")
            XCTAssertEqual(result.map(\.cell.x), expected.map(\.cell.x), "capacity \(capacity)")
            XCTAssertEqual(result.map(\.cell.y), expected.map(\.cell.y), "capacity \(capacity)")
            XCTAssertEqual(result.map(\.metadata.y), expected.map(\.metadata.y), "capacity \(capacity)")
            // Dawna sieć bitoniczna: log2(n)·(log2(n)+1)/2 dispatchy.
            let levels = capacity.trailingZeroBitCount
            XCTAssertLessThan(dispatches, max(2, levels * (levels + 1) / 2), "capacity \(capacity)")
            if capacity <= 256 { XCTAssertEqual(dispatches, 1, "capacity \(capacity)") }
            if capacity == 512 { XCTAssertEqual(dispatches, 3) }
        }
    }

    // MARK: wygładzanie konturu

    func testFusedContourSmoothingIsBitIdenticalToThirteenPasses() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        for stride in [8, 64, 96] {
            let bubbles = 12
            var generator = Generator(state: UInt64(stride) &* 104729)
            let counts: [UInt32] = (0..<bubbles).map { index in
                switch index % 4 {
                case 0: return UInt32(stride)
                case 1: return UInt32(3 + Int(generator.next()) % (stride - 3))
                case 2: return 3
                default: return 0
                }
            }
            let values: [SIMD4<Float>] = (0..<bubbles * stride).map { _ in
                SIMD4(generator.unit(), generator.unit() * 0.3, generator.unit(), generator.unit())
            }
            let sentinel = [SIMD4<Float>](repeating: SIMD4(7, 7, 7, 7), count: bubbles * stride)
            let countBuffer = try makeBuffer(counts, device: device)
            let control = try makeBuffer([NativeMetalControl(counts: SIMD4(UInt32(bubbles), 0, 0, 0), physics: .zero,
                                                             contactDamping: .zero)], device: device)
            let contour = try makeBuffer([NativeMetalContourControl(counts: SIMD4(UInt32(stride), 0, 0, 0),
                                                                    shape: SIMD4(1, 0, 4, 0))], device: device)
            var outputs: [[SIMD4<Float>]] = []
            var safeties: [UInt32] = []
            var dispatchCounts: [Int] = []
            for fused in [false, true] {
                let input = try makeBuffer(values, device: device)
                let output = try makeBuffer(sentinel, device: device)
                let safety = try makeBuffer([UInt32](repeating: 0, count: 8), device: device)
                dispatchCounts.append(try run(device: device) {
                    NativeMetalContourSmoothing.encode($0, pipelines: pipelines, input: input, output: output,
                                                       counts: countBuffer, control: control, contour: contour, safety: safety,
                                                       bubbleCount: bubbles, stride: stride, fused: fused)
                })
                outputs.append(Array(UnsafeBufferPointer(
                    start: output.contents().bindMemory(to: SIMD4<Float>.self, capacity: bubbles * stride), count: bubbles * stride)))
                safeties.append(safety.contents().load(fromByteOffset: 12, as: UInt32.self))
            }
            XCTAssertEqual(dispatchCounts[0], NativeMetalContourSmoothing.passCount)
            XCTAssertEqual(dispatchCounts[1], 1)
            XCTAssertEqual(safeties, [0, 0])
            let legacyBits = outputs[0].flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern] }
            let fusedBits = outputs[1].flatMap { [$0.x.bitPattern, $0.y.bitPattern, $0.z.bitPattern, $0.w.bitPattern] }
            XCTAssertEqual(fusedBits, legacyBits, "stride \(stride)")
            // Smoothing zmienia nacisk: wynik nie jest kopią wejścia dla pełnego konturu.
            XCTAssertNotEqual(outputs[1][0].x, values[0].x)
            // Wpisy poza `count` zostają nietknięte.
            XCTAssertEqual(outputs[1][3 * stride], SIMD4(7, 7, 7, 7))
        }
    }
}
