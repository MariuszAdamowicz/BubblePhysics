import XCTest
import Metal
@testable import BubblePhysicsNativeMetal
@testable import BubblePhysicsNativeMetalDiagnostics

@MainActor
final class NativeMetalContainmentParallelTests: XCTestCase {
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
    func encode(_ name: String, buffers: [MTLBuffer], groups: Int) async throws {
        let pipeline = try await device.makeComputePipelineState(function: XCTUnwrap(library.makeFunction(name: name)))
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
        encoder.setComputePipelineState(pipeline)
        for (i, b) in buffers.enumerated() { encoder.setBuffer(b, offset: 0, index: i) }
        encoder.dispatchThreadgroups(.init(width: groups, height: 1, depth: 1),
            threadsPerThreadgroup: .init(width: pipeline.threadExecutionWidth, height: 1, depth: 1))
        encoder.endEncoding()
        _ = try await NativeMetalCommandExecutor().complete(command)
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
