import BubblePhysicsModel
import Metal
@testable import BubblePhysicsNativeMetal
import XCTest

/// P-B-80 (etap 8): krok bez więzów przygotowuje bufory więzów tak samo jak `prepare` z pustą listą, ale bez list identyfikatorów.
@MainActor
final class NativeJointStateEmptyTests: XCTestCase {
    private func bytes(_ buffer: MTLBuffer) -> [UInt8] {
        Array(UnsafeBufferPointer(start: buffer.contents().assumingMemoryBound(to: UInt8.self), count: buffer.length))
    }

    func testPreparingWithoutJointsMatchesPreparingWithAnEmptyList() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let reference = NativeJointState(device: device), fast = NativeJointState(device: device)
        let bubbles = (1...7).map { ObjectID(rawValue: UInt64($0)) }, bodies = (20...22).map { ObjectID(rawValue: UInt64($0)) }
        try reference.prepare([], bubbleIDs: bubbles, bodyIDs: bodies, iterations: 6)
        try fast.prepareWithoutJoints(bubbleCount: bubbles.count, bodyCount: bodies.count, iterations: 6)
        XCTAssertEqual(fast.count, 0)
        XCTAssertEqual(fast.count, reference.count)
        XCTAssertEqual(bytes(fast.control), bytes(reference.control))
        XCTAssertEqual(bytes(fast.ranges), bytes(reference.ranges))
        XCTAssertEqual(bytes(fast.exclusions), bytes(reference.exclusions))
        XCTAssertEqual(fast.control.contents().load(as: SIMD4<UInt32>.self), SIMD4(0, 7, 3, 6))
    }

    func testPreparingWithoutJointsDropsJointsOfTheEarlierStep() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let state = NativeJointState(device: device)
        let ids = (1...3).map { ObjectID(rawValue: UInt64($0)) }
        let joint = try Joint(id: JointID(rawValue: 1), bodyA: ids[0], bodyB: ids[1], kind: .weld, collideConnected: true)
        try state.prepare([joint], bubbleIDs: ids, bodyIDs: [], iterations: 4)
        XCTAssertEqual(state.count, 1)
        try state.prepareWithoutJoints(bubbleCount: 3, bodyCount: 0, iterations: 4)
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.control.contents().load(as: SIMD4<UInt32>.self), SIMD4(0, 3, 0, 4))
    }
}
