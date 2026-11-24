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
        try state.prepare([joint], bubbleIDs: [], bodyIDs: ids, iterations: 4)
        XCTAssertEqual(state.count, 1)
        try state.prepareWithoutJoints(bubbleCount: 0, bodyCount: 3, iterations: 4)
        XCTAssertEqual(state.count, 0)
        XCTAssertEqual(state.control.contents().load(as: SIMD4<UInt32>.self), SIMD4(0, 0, 3, 4))
    }

    /// Silnik 4.0.0 nie ma przegubów z bańkami: więz z końcem w bańce nie trafia do GPU, a wykluczenie kolizji pary (collideConnected == false)
    /// zostaje, więc bańka nie styka się z połączoną bryłą. Więz bryła–bryła i bryła–świat trafia do GPU jak dotąd.
    func testJointsWithABubbleEndAreNotSentToTheGPUButKeepTheirCollisionExclusion() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let state = NativeJointState(device: device)
        let bubble = ObjectID(rawValue: 1), bodies = [ObjectID(rawValue: 20), ObjectID(rawValue: 21)]
        let withBubble = try Joint(id: JointID(rawValue: 1), bodyA: bubble, bodyB: bodies[0], kind: .weld, collideConnected: false)
        let bubbleToWorld = try Joint(id: JointID(rawValue: 2), bodyA: bubble, bodyB: nil, kind: .weld)
        let bodyToBody = try Joint(id: JointID(rawValue: 3), bodyA: bodies[0], bodyB: bodies[1], kind: .weld, collideConnected: true)
        try state.prepare([withBubble, bubbleToWorld, bodyToBody], bubbleIDs: [bubble], bodyIDs: bodies, iterations: 4)
        XCTAssertEqual(state.count, 1, "do GPU trafia tylko więz bryła–bryła")
        let record = state.records.contents().load(as: NativeJointRecord.self)
        XCTAssertEqual(record.identity.x, 3)
        XCTAssertEqual(state.control.contents().load(as: SIMD4<UInt32>.self), SIMD4(1, 1, 2, 4))
        // Wykluczenie: wiersz bańki (encja 0) i bryły 20 (encja 1) niosą się nawzajem, bryła 21 (encja 2) nic.
        let ranges = state.ranges.contents().bindMemory(to: SIMD4<UInt32>.self, capacity: 3)
        let partners = state.exclusions.contents().bindMemory(to: UInt64.self, capacity: 2)
        XCTAssertEqual(ranges[0].w, 1)
        XCTAssertEqual(partners[Int(ranges[0].z)], 20)
        XCTAssertEqual(ranges[1].w, 1)
        XCTAssertEqual(partners[Int(ranges[1].z)], 1)
        XCTAssertEqual(ranges[2].w, 0)
    }
}
