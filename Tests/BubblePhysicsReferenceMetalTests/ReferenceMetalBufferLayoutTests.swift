import XCTest
import BubblePhysicsReference
@testable import BubblePhysicsReferenceMetal

final class ReferenceMetalBufferLayoutTests: XCTestCase {
    func testSnapshotPreservesSortedIDsCentersAndSegmentVelocity() throws {
        var world = ReferenceWorld(configuration: .default, broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 91), center: .init(x: 3, y: 4), mass: 2, targetRadius: 5))
        world.addBubble(try .init(id: .init(rawValue: -7), center: .init(x: -1, y: 2), velocity: .init(x: 8, y: 9), mass: 4, targetRadius: 6))
        world.addSegment(.kinematicSegment(id: .init(rawValue: 19), previousA: .zero, previousB: .init(x: 2, y: 0), currentA: .init(x: 1, y: 2), currentB: .init(x: 3, y: 2), timeStep: 0.5, angularVelocity: 7))
        let snapshot = ReferenceMetalSnapshot(world: world)
        world.updateBubble(try .init(id: .init(rawValue: -7), center: .zero, mass: 1, targetRadius: 1))
        XCTAssertEqual(snapshot.bubbles.map { $0.identity.x }, [-7, 91])
        XCTAssertEqual(snapshot.centers, [SIMD2(-1, 2), SIMD2(3, 4)])
        XCTAssertEqual(snapshot.velocities, [SIMD2(8, 9), .zero])
        XCTAssertEqual(snapshot.segments[0].velocity, SIMD4(2, 4, 7, 0))
        XCTAssertEqual(snapshot.configuration, world.configuration)
    }

    func testRecordsHaveSixteenByteABIAlignment() {
        XCTAssertEqual(MemoryLayout<ReferenceMetalBubble>.alignment, 16)
        XCTAssertEqual(MemoryLayout<ReferenceMetalSegment>.alignment, 16)
        XCTAssertEqual(MemoryLayout<ReferenceMetalContact>.alignment, 16)
        XCTAssertEqual(MemoryLayout<ReferenceMetalComponent>.alignment, 16)
        XCTAssertEqual(MemoryLayout<ReferenceMetalBubble>.stride % 16, 0)
        XCTAssertEqual(MemoryLayout<ReferenceMetalSegment>.stride % 16, 0)
        XCTAssertEqual(MemoryLayout<ReferenceMetalContact>.stride % 16, 0)
        XCTAssertEqual(MemoryLayout<ReferenceMetalComponent>.stride % 16, 0)
    }

    func testContactPackingPreservesWideIDsOptionalZeroAndCompression() {
        let packed = ReferenceMetalContact(.init(
            id: .init(rawValue: UInt64.max), kind: .bubbleSegment,
            bubbleA: .init(rawValue: Int.min), bubbleB: .init(rawValue: 0), segment: .init(rawValue: Int.max),
            normal: .init(x: 1, y: 2), pointQ: .init(x: 3, y: 4), penetration: 5,
            timeOfImpact: 0, allowedSide: -1, accumulatedCompression: 6, compressionA: 7,
            compressionB: 8, pressure: 9, effectiveStiffness: 10, age: 11, contourHalfLength: 0))
        XCTAssertEqual(packed.identity, SIMD2(UInt64.max, 63))
        XCTAssertEqual(packed.bubbles, SIMD2(Int64.min, 0))
        XCTAssertEqual(packed.segmentAndAge, SIMD2(Int64.max, 11))
        XCTAssertEqual(packed.geometry, SIMD4(1, 2, 3, 4))
        XCTAssertEqual(packed.timing, SIMD4(5, 0, -1, 0))
        XCTAssertEqual(packed.compression, SIMD4(6, 7, 8, 9))
        XCTAssertEqual(packed.response.x, 10)
    }
}
