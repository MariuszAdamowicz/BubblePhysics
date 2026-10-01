import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalBufferLayoutTests: XCTestCase {
    func testSnapshotPreservesAdaptiveBoundaryRangesAndParticlePositions() {
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 10, y: 20), restArea: .pi * 25)
        world.addBubble(center: Vector2(x: 50, y: 60), restArea: .pi * 29 * 29)

        let snapshot = MetalWorldSnapshot(world: world)

        XCTAssertEqual(snapshot.bubbleRanges.map(\.boundaryCount), [8, 23])
        XCTAssertEqual(snapshot.particles.first?.position, SIMD2<Float>(10, 20))
        XCTAssertEqual(snapshot.particles.count, 33)
    }

    func testSharedSwiftMetalRecordsHaveExpectedStride() {
        XCTAssertEqual(MemoryLayout<MetalParticle>.stride % 16, 0)
        XCTAssertEqual(MemoryLayout<MetalBubbleRange>.stride % 16, 0)
        XCTAssertEqual(MemoryLayout<MetalSpringConstraint>.stride, 24)
    }
}
