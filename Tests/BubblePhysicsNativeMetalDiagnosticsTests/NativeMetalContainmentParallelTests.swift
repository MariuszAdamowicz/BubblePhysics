import XCTest
import Metal
import BubblePhysicsReference
@testable import BubblePhysicsNativeMetal
@testable import BubblePhysicsNativeMetalDiagnostics

@MainActor
final class NativeMetalContainmentParallelTests: XCTestCase {
    // Break caught: an inactive GPU repair pass must copy ping/pong positions,
    // rather than run another correction or leave stale output behind.
    func testInactiveRepairCopiesPositionsWithoutCorrection() async throws {
        let fixture = try await ContainmentKernelFixture()
        let result = try await fixture.separate(active: false)
        XCTAssertEqual(result.positions, [SIMD4<Float>(0, 0, 0, 0), SIMD4(0.25, 0, 0, 0), SIMD4(0, 0.25, 0, 0)])
        XCTAssertEqual(result.nextActive, 0)
    }

    // Hand-derived: inverse masses 1/3 and 1 give each large-bubble correction weight 1/4 and each small-bubble
    // correction weight 3/4. Bez limitu małe bańki ruszyłyby się o 1,3125, a duża o 0,4375 po osi. Limit 0,25·r
    // (małe 0,25, duża 0,75) skaluje każdą parę jednym współczynnikiem 0,25/1,3125 = 1/5,25: małe bańki idą o 0,25
    // (do 0,5), a duża o 0,4375 · 0,1905 = 0,0833 po osi, czyli pęd pary (3 · 0,0833 = 1 · 0,25) zostaje zachowany.
    func testParallelRepairAggregatesOpposingAxesAndRepeatsExactly() async throws {
        let fixture = try await ContainmentKernelFixture()
        let first = try await fixture.separate(active: true)
        XCTAssertEqual(first.positions[0].x, -0.083333, accuracy: 0.00001)
        XCTAssertEqual(first.positions[0].y, -0.083333, accuracy: 0.00001)
        XCTAssertEqual(first.positions[1].x, 0.5, accuracy: 0.00001)
        XCTAssertEqual(first.positions[2].y, 0.5, accuracy: 0.00001)
        XCTAssertEqual(first.nextActive, 1)
        for _ in 0..<5 {
            let repeated = try await fixture.separate(active: true)
            XCTAssertEqual(first.positions, repeated.positions)
        }
    }

    // Każda mała bańka (r = 1) wykorzystuje cały budżet 0,25 z jednej pary z dużą, a duża dostaje cztery równe, przeciwne
    // zestawy korekcji, które znoszą się dokładnie.
    func testParallelRepairIncludesNeighborsBeyondOneSIMDWidth() async throws {
        let fixture = try await ContainmentKernelFixture()
        let directions: [SIMD4<Float>] = [SIMD4(0.25, 0, 0, 0), SIMD4(0, 0.25, 0, 0),
                                         SIMD4(-0.25, 0, 0, 0), SIMD4(0, -0.25, 0, 0)]
        let positions = [SIMD4<Float>.zero] + (0..<64).map { directions[$0 % 4] }
        let first = try await fixture.separate(active: true, positions: positions)
        XCTAssertEqual(first.positions[0], .zero, "Opposite corrections cancel exactly")
        for i in 1..<65 {
            let expected = directions[(i - 1) % 4] * 2
            XCTAssertEqual(first.positions[i].x, expected.x, accuracy: 0.00001)
            XCTAssertEqual(first.positions[i].y, expected.y, accuracy: 0.00001)
        }
        let repeated = try await fixture.separate(active: true, positions: positions)
        XCTAssertEqual(first.positions, repeated.positions)
    }

    func testRepairEarlyOutRetainsCompletedStateInEveryPingPongPass() async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1, linearDamping: 0, angularDamping: 0),
                                   broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .zero, mass: 3, targetRadius: 3))
        world.addBubble(try .init(id: .init(rawValue: 2), center: .zero, mass: 1, targetRadius: 1))
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()),
            configuration: .init(contactCompliance: 1e6))
        let frame = try await solver.executeFrame(world: world, scenarioStep: 1)
        let flags = try XCTUnwrap(solver.persistentState).containmentRepairActive.contents().bindMemory(to: UInt32.self, capacity: 9)
        XCTAssertEqual(flags[0], 1)
        XCTAssertEqual(flags[1], 1, "First repair must trigger the next pass")
        let firstStable = try XCTUnwrap((1..<8).first { flags[$0] == 0 })
        XCTAssertTrue((firstStable..<9).allSatisfy { flags[$0] == 0 }, "Inactive passes must never reactivate after copying")
        // Limit korekcji 0,25·r: małą bańkę (r = 1) przesuwa 0,25, dużą (r = 3) 0,25/3, a pierwszy przebieg wyczerpuje
        // budżety obu baniek, więc kolejne przebiegi już nic nie zmieniają.
        XCTAssertEqual((frame.bubbles[0].center - frame.bubbles[1].center).length, 0.25 + 0.25 / 3, accuracy: 0.0001)
        XCTAssertEqual(frame.profile.commandBufferCount, 1)
    }

    // Break caught: pair mapping skips the final partial SIMDgroup or changes strict nominal-containment/finite
    // semantics. Expected values are literals. Containment no longer lights bit 2: the validator counts pairs in
    // safety+4 (diagnostics.x), and only a non-finite distance still sets the failure bit 1.
    func testParallelValidatorCountsStrictContainmentWithoutFailureBit() async throws {
        let fixture = try await ContainmentKernelFixture()
        for (distance, expectedPairs, expectedFlags): (Float, UInt32, UInt32) in
            [(1.999, 1, 0), (2, 0, 0), (2.001, 0, 0), (.infinity, 0, 1)] {
            let result = try await fixture.validate(distance: distance)
            XCTAssertEqual(result.pairs, expectedPairs, "distance \(distance)")
            XCTAssertEqual(result.flags, expectedFlags, "distance \(distance)")
        }
    }

    // Each contained pair adds one: radii 3, 1, 1 at one point give pairs (3,1), (3,1) and no pair of the equal ones.
    func testParallelValidatorCountsEveryContainedPair() async throws {
        let fixture = try await ContainmentKernelFixture()
        let result = try await fixture.validate(positions: [SIMD4<Float>](repeating: .zero, count: 3), bubbleCount: 3)
        XCTAssertEqual(result.pairs, 2)
        XCTAssertEqual(result.flags, 0)
    }
}

@MainActor
private final class ContainmentKernelFixture {
    let device: MTLDevice
    let queue: MTLCommandQueue
    let library: MTLLibrary
    init() async throws {
        device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        queue = try XCTUnwrap(device.makeCommandQueue())
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shaders = root.appendingPathComponent("Sources/BubblePhysicsNativeMetal/Shaders")
        let source = try ["NativeGeometryKernels", "NativeXPBDKernels", "NativePostSolveKernels"].map {
            try String(contentsOf: shaders.appendingPathComponent($0 + ".metal-source"), encoding: .utf8)
        }.joined(separator: "\n")
        let options = MTLCompileOptions(); options.fastMathEnabled = false
        library = try await device.makeLibrary(source: source, options: options)
    }
    func buffer<T>(_ values: [T]) throws -> MTLBuffer {
        try values.withUnsafeBytes { bytes in
            try XCTUnwrap(device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared))
        }
    }
    func bubbles(_ count: Int) throws -> [NativeMetalBubble] {
        try (0..<count).map { i in
            NativeMetalBubble(try .init(id: .init(rawValue: i + 1), center: .zero,
                mass: i == 0 ? 3 : 1, targetRadius: i == 0 ? 3 : 1))
        }
    }
    func encode(_ name: String, buffers: [MTLBuffer], totals: MTLBuffer? = nil, groups: Int) async throws {
        let pipeline = try await device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: name)))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        if name == "nativeSeparateContainedBubbles" {
            encoder.setThreadgroupMemoryLength(pipeline.threadExecutionWidth * MemoryLayout<SIMD2<Float>>.stride, index: 0)
        }
        for (i, b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        if let totals { encoder.setBuffer(totals, offset: 0, index: 12) }
        encoder.dispatchThreadgroups(.init(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        _ = try await NativeMetalCommandExecutor().complete(command)
    }
    func separate(active: Bool, positions: [SIMD4<Float>] = [SIMD4(0, 0, 0, 0), SIMD4(0.25, 0, 0, 0), SIMD4(0, 0.25, 0, 0)]) async throws -> (positions: [SIMD4<Float>], nextActive: UInt32) {
        let count = positions.count
        let input = try buffer(positions)
        let output = try buffer(Array(repeating: SIMD4<Float>(999, 999, 999, 999), count: count))
        let flags = try buffer([UInt32(active ? 1 : 0), 0])
        // Pass 0: czyta połówkę 0 (sumy z solvera, tu zero), pisze połówkę 1.
        let totals = try buffer([SIMD2<Float>](repeating: .zero, count: 2 * count))
        try await encode("nativeSeparateContainedBubbles", buffers: [try buffer(bubbles(count)), input, output,
            try buffer([NativeMetalControl(counts: SIMD4(UInt32(count), 0, 0, 0), physics: .zero, contactDamping: .zero)]),
            try buffer([NativeMetalSolverControl(counts: .zero, physics: SIMD4(0, 0.00001, 0, 0))]),
            try buffer([UInt32](repeating: 0, count: count)), try buffer([UInt32](repeating: 0, count: 4)),
            flags, try buffer([UInt32(0)])], totals: totals, groups: count)
        let pointer = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: count)
        return (Array(UnsafeBufferPointer(start: pointer, count: count)), flags.contents().load(fromByteOffset: 4, as: UInt32.self))
    }
    func validate(distance: Float) async throws -> (flags: UInt32, pairs: UInt32) {
        let positions = (0..<33).map { i -> SIMD4<Float> in
            if i == 32 { return SIMD4(distance, 0, 0, 0) }
            if i == 31 { return .zero }
            return SIMD4(100 + Float(i) * 20, 0, 0, 0)
        }
        var records = try bubbles(33)
        records[0].physical.z = 1
        records[31].physical.z = 3
        return try await validate(records: records, positions: positions)
    }
    func validate(positions: [SIMD4<Float>], bubbleCount: Int) async throws -> (flags: UInt32, pairs: UInt32) {
        try await validate(records: bubbles(bubbleCount), positions: positions)
    }
    /// Bufor `safety` ma dwa słowa `uint4` jak `NativeMetalSafetyControl`: bity błędów w `counts.w`, licznik par w `diagnostics.x`.
    private func validate(records: [NativeMetalBubble], positions: [SIMD4<Float>]) async throws -> (flags: UInt32, pairs: UInt32) {
        let count = records.count
        let safety = try buffer([UInt32](repeating: 0, count: 8))
        try await encode("nativeValidateBubbleContainment", buffers: [try buffer(records), try buffer(positions),
            try buffer([NativeMetalControl(counts: SIMD4(UInt32(count), 0, 0, 0), physics: .zero, contactDamping: .zero)]),
            try buffer([NativeMetalSolverControl(counts: .zero, physics: SIMD4(0, 0.00001, 0, 0))]), safety], groups: count)
        return (safety.contents().load(fromByteOffset: 12, as: UInt32.self),
                safety.contents().load(fromByteOffset: 16, as: UInt32.self))
    }
}
