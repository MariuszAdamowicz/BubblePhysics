import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalSimulationSessionTests: XCTestCase {
    func testEncodeFrameReusesParticleBuffer() throws {
        let (session, queue) = try makeSession(.inspection)
        let firstCommandBuffer = try XCTUnwrap(queue.makeCommandBuffer())
        let first = try session.encodeFrame(input: .init(), commandBuffer: firstCommandBuffer)
        let second = try session.encodeFrame(input: .init(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer()))

        XCTAssertTrue(first.particleBuffer === second.particleBuffer)
        XCTAssertTrue(first.rangeBuffer === second.rangeBuffer)
        XCTAssertEqual(firstCommandBuffer.status, .notEnqueued, "Session must not commit its caller-owned command buffer")
    }

    func testResetReallocatesOnlyWhenCapacityMustGrow() throws {
        let (session, queue) = try makeSession(.inspection)
        let original = try session.encodeFrame(input: .init(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())).particleBuffer

        try session.reset(snapshot: MetalWorldSnapshot(world: try PrototypeSceneFactory.make(.inspection)))
        let sameCapacity = try session.encodeFrame(input: .init(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())).particleBuffer
        XCTAssertTrue(original === sameCapacity)

        try session.reset(snapshot: MetalWorldSnapshot(world: try PrototypeSceneFactory.make(.stress)))
        let grown = try session.encodeFrame(input: .init(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())).particleBuffer
        XCTAssertFalse(original === grown)
    }

    func testResetCancelsGrab() throws {
        let (session, _) = try makeSession(.inspection)
        session.updateGrab(.init(particleIndex: 0, target: SIMD2<Float>(12, 34)))
        XCTAssertTrue(session.hasActiveGrab)

        try session.reset(snapshot: MetalWorldSnapshot(world: try PrototypeSceneFactory.make(.inspection)))

        XCTAssertFalse(session.hasActiveGrab)
    }

    func testFailureStatusStopsFurtherEncoding() throws {
        let (session, queue) = try makeSession(.inspection)
        session.recordFailureForTesting(.overflow)

        XCTAssertEqual(session.status, .failed(.overflow))
        XCTAssertThrowsError(try session.encodeFrame(input: .init(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())))
    }

    func testNonFiniteFailureStatusStopsFurtherEncoding() throws {
        let (session, queue) = try makeSession(.inspection)
        session.recordFailureForTesting(.nonFinite)

        XCTAssertEqual(session.status, .failed(.nonFinite))
        XCTAssertThrowsError(try session.encodeFrame(input: .init(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer())))
    }

    private func makeSession(_ size: PrototypeSceneSize) throws -> (MetalSimulationSession, MTLCommandQueue) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let snapshot = MetalWorldSnapshot(world: try PrototypeSceneFactory.make(size))
        return (
            try MetalSimulationSession(snapshot: snapshot, device: device),
            try XCTUnwrap(device.makeCommandQueue())
        )
    }
}
