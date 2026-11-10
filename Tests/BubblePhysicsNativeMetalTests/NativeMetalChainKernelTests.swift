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

    // MARK: kandydaci brył (zadanie 94)

    private struct RigidCandidatesResult: Equatable {
        var rows: [UInt32]
        var rowCounts: [UInt32]
        var overflow: [UInt32]
    }

    private func encodeRigidCandidates(device: MTLDevice, groupWidth: Int, bubbleCount: Int, bodyCount: Int,
                                       limit: Int, seed: UInt64) throws -> (RigidCandidatesResult, Int) {
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        var generator = Generator(state: seed)
        let bubbles: [NativeMetalBubble] = (0..<bubbleCount).map { index in
            var bubble = NativeMetalBubble(NativeSolverBubble(id: NativeSolverBubbleID(rawValue: 1000 + index),
                center: .zero, mass: 1, targetRadius: 0.4 + generator.unit() * 0.4))
            bubble.position = SIMD4(generator.unit() * 8, generator.unit() * 8, generator.unit() * 8, generator.unit() * 8)
            // Co siódma bańka nie przepuszcza filtra bryły.
            if index % 7 == 3 { bubble.filter = SIMD4(1, 0, 0, NativeMetalFilter.encodeLayer(0)) }
            return bubble
        }
        let positions: [SIMD4<Float>] = bubbles.map { SIMD4($0.position.x, $0.position.y, 0, 0) }
        let bodies: [NativeRigidBody] = (0..<bodyCount).map { index in
            var body = NativeRigidBody(identity: SIMD2(UInt64(5000 + index), 0),
                pose: SIMD4(3 + Float(index), 4, 0, 0), previous: SIMD4(2.5 + Float(index), 4.2, 0, 0),
                motion: .zero, physical: SIMD4(1, 1, 2.5, 0), ranges: .zero, flags: .zero,
                filter: NativeMetalFilter.default, shape: SIMD4(index == 1 ? 1 : 0, 1, 0, 0), limits: .zero)
            body.flags = SIMD4(index == 2 ? 1 : 0, 0, 0, 0)
            return body
        }
        let entityCount = bubbleCount + bodyCount
        var ranges = [SIMD4<UInt32>](repeating: .zero, count: entityCount)
        // Pierwsza bryła nie koliduje z dwiema bańkami (więz bez collideConnected).
        ranges[bubbleCount] = SIMD4(0, 0, 0, 2)
        let partners: [UInt64] = [1005, 1010]
        let rowCapacity = bodyCount * limit
        let rows = try makeBuffer([UInt32](repeating: 0xDEAD_BEEF, count: rowCapacity * 8), device: device)
        let rowCounts = try makeBuffer([UInt32](repeating: 0, count: bodyCount * 2), device: device)
        let overflow = try makeBuffer([UInt32](repeating: 0, count: 2), device: device)
        let control = try makeBuffer([SIMD4(UInt32(bodyCount), UInt32(bubbleCount), UInt32(limit), 0)], device: device)
        let dispatches = try run(device: device) {
            NativeMetalRigidCandidates.encode($0, pipelines: pipelines, bodies: try! makeBuffer(bodies, device: device),
                bubbles: try! makeBuffer(bubbles, device: device), positions: try! makeBuffer(positions, device: device),
                control: control, rows: rows, rowCounts: rowCounts, overflow: overflow,
                jointRanges: try! makeBuffer(ranges, device: device), jointPartners: try! makeBuffer(partners, device: device),
                bodyCount: bodyCount, groupWidth: groupWidth)
        }
        func read(_ buffer: MTLBuffer, _ count: Int) -> [UInt32] {
            Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt32.self, capacity: count), count: count))
        }
        return (RigidCandidatesResult(rows: read(rows, rowCapacity * 8), rowCounts: read(rowCounts, bodyCount * 2),
                                      overflow: read(overflow, 2)), dispatches)
    }

    func testCooperativeRigidCandidatesAreBitIdenticalToTheSerialScan() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // Rzadka scena (poniżej limitu) i gęsta (wiersz przepełniony, kandydaci odpadają).
        for (bubbleCount, limit) in [(40, 32), (300, 32), (300, 128), (513, 64)] {
            let serial = try encodeRigidCandidates(device: device, groupWidth: 1, bubbleCount: bubbleCount, bodyCount: 3,
                                                    limit: limit, seed: UInt64(bubbleCount * 31 + limit))
            XCTAssertGreaterThan(serial.0.rowCounts[0], 0, "bubbles \(bubbleCount)")
            if bubbleCount >= 300, limit <= 64 { XCTAssertGreaterThan(serial.0.overflow[0], 0, "oczekiwano przepełnienia") }
            for width in [32, 64, 128, 256] {
                let cooperative = try encodeRigidCandidates(device: device, groupWidth: width, bubbleCount: bubbleCount,
                                                             bodyCount: 3, limit: limit, seed: UInt64(bubbleCount * 31 + limit))
                XCTAssertEqual(cooperative.0, serial.0, "bubbles \(bubbleCount) limit \(limit) width \(width)")
                XCTAssertEqual(cooperative.1, 1)
            }
        }
    }

    // MARK: dane renderu (zadanie 94)

    private struct RenderPreparationResult: Equatable {
        var bubbles: [UInt32]
        var packets: [UInt32]
        var points: [UInt32]
        var deformation: [UInt32]
        var safety: [UInt32]
    }

    private func prepareRenderData(device: MTLDevice, grouped: Bool, stride: Int, maxEdge: Float,
                                   seed: UInt64) throws -> (RenderPreparationResult, Int) {
        let pipelines = try NativeMetalPipelineCache.pipelines(for: device).stages
        var generator = Generator(state: seed)
        let bubbleCount = 12
        let bubbles: [NativeMetalBubble] = (0..<bubbleCount).map { index in
            var bubble = NativeMetalBubble(NativeSolverBubble(id: NativeSolverBubbleID(rawValue: 10 + index),
                center: .zero, mass: 1, targetRadius: 0.3 + generator.unit()))
            bubble.position = SIMD4(generator.unit() * 6 - 3, generator.unit() * 6 - 3, 0, 0)
            bubble.deformation = SIMD4(0.9, 0.9, 5, 6)
            bubble.bounds = SIMD4(-1, -1, 1, 1)
            return bubble
        }
        let counts: [UInt32] = (0..<bubbleCount).map { index in
            switch index % 5 {
            case 0: return UInt32(stride)
            case 1: return UInt32(3 + Int(generator.next()) % (stride - 3))
            case 2: return 3
            case 3: return 1
            default: return 0
            }
        }
        // Ostre piki nacisku wymuszają majorantę o ograniczonym nachyleniu w obie strony i szew koła.
        let deformation: [SIMD4<Float>] = (0..<bubbleCount * stride).map { _ in
            let spike: Float = generator.next() % 9 == 0 ? generator.unit() * 0.5 : 0
            return SIMD4(spike + generator.unit() * 0.05, generator.unit(), 3, 4)
        }
        let points = try makeBuffer([SIMD2<Float>](repeating: SIMD2(9, 9), count: bubbleCount * stride), device: device)
        let packets = try makeBuffer([NativeMetalRenderPacket](
            repeating: NativeMetalRenderPacket(identity: .zero, geometry: SIMD4(5, 5, 5, 5), deformation: SIMD4(5, 5, 5, 5)),
            count: bubbleCount), device: device)
        let bubbleBuffer = try makeBuffer(bubbles, device: device)
        let deformationBuffer = try makeBuffer(deformation, device: device)
        let safety = try makeBuffer([UInt32](repeating: 0, count: 4), device: device)
        let control = try makeBuffer([NativeMetalControl(counts: SIMD4(UInt32(bubbleCount), 0, 0, 0), physics: .zero,
                                                         contactDamping: .zero)], device: device)
        let contour = try makeBuffer([NativeMetalContourControl(counts: SIMD4(UInt32(stride), 0, 0, 0),
                                                                shape: SIMD4(maxEdge, 0, 4, 0))], device: device)
        let dispatches = try run(device: device) {
            NativeMetalRenderPreparation.encode($0, pipelines: pipelines, bubbles: bubbleBuffer,
                deformation: deformationBuffer, counts: try! makeBuffer(counts, device: device), points: points,
                packets: packets, control: control, contour: contour, safety: safety, bubbleCount: bubbleCount,
                stride: stride, grouped: grouped)
        }
        func bits<T>(_ buffer: MTLBuffer, _ type: T.Type, _ count: Int) -> [UInt32] {
            let words = count * MemoryLayout<T>.stride / 4
            return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: UInt32.self, capacity: words), count: words))
        }
        return (RenderPreparationResult(bubbles: bits(bubbleBuffer, NativeMetalBubble.self, bubbleCount),
            packets: bits(packets, NativeMetalRenderPacket.self, bubbleCount),
            points: bits(points, SIMD2<Float>.self, bubbleCount * stride),
            deformation: bits(deformationBuffer, SIMD4<Float>.self, bubbleCount * stride),
            safety: bits(safety, UInt32.self, 4)), dispatches)
    }

    func testGroupedRenderPreparationIsBitIdenticalToThePerBubbleThread() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        // 8 i 64 to potęgi dwójki, 96 i 100 nie; duża dopuszczalna krawędź nie zgłasza błędu,
        // mała ustawia bit 4 w bezpieczniku w obu wariantach.
        for stride in [8, 64, 96, 100, 256] {
            for maxEdge in [Float(10), Float(0.05)] {
                let seed = UInt64(stride) &* 7919 &+ UInt64(maxEdge * 100)
                let legacy = try prepareRenderData(device: device, grouped: false, stride: stride, maxEdge: maxEdge, seed: seed)
                let grouped = try prepareRenderData(device: device, grouped: true, stride: stride, maxEdge: maxEdge, seed: seed)
                XCTAssertEqual(legacy.1, 1)
                XCTAssertEqual(grouped.1, 1)
                XCTAssertEqual(grouped.0.safety, legacy.0.safety, "stride \(stride) edge \(maxEdge)")
                XCTAssertEqual(grouped.0.bubbles, legacy.0.bubbles, "stride \(stride) edge \(maxEdge)")
                XCTAssertEqual(grouped.0.packets, legacy.0.packets, "stride \(stride) edge \(maxEdge)")
                XCTAssertEqual(grouped.0.points, legacy.0.points, "stride \(stride) edge \(maxEdge)")
                XCTAssertEqual(grouped.0.deformation, legacy.0.deformation, "stride \(stride) edge \(maxEdge)")
                // Test nie jest zgodnością zer: pakiet bańki z pełnym konturem został zapisany.
                XCTAssertNotEqual(legacy.0.packets[2], 5)
                if maxEdge < 1 { XCTAssertNotEqual(legacy.0.safety[3] & 4, 0, "bit przekroczonej krawędzi") }
                else { XCTAssertEqual(legacy.0.safety[3], 0) }
            }
        }
    }
}
