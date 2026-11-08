import BubblePhysics
@testable import BubblePhysicsMetalRender
import XCTest

@MainActor
final class TriangulationTests: XCTestCase {
    func testConcaveRingTriangulationIndexesTheRingAndCoversItsArea() {
        // Pierścień w kształcie litery L o polu 3.
        let ring: [WorldPoint] = [.init(0, 0), .init(2, 0), .init(2, 1), .init(1, 1), .init(1, 2), .init(0, 2)]
        let indices = BubblePhysicsMetalRender.triangulate(ring)
        XCTAssertEqual(indices.count, (ring.count - 2) * 3)
        XCTAssertTrue(indices.allSatisfy { ring.indices.contains($0) })
        var area: Float = 0
        for start in stride(from: 0, to: indices.count, by: 3) {
            let a = ring[indices[start]], b = ring[indices[start + 1]], c = ring[indices[start + 2]]
            area += abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)) / 2
        }
        XCTAssertEqual(area, 3, accuracy: 1e-5)
    }

    func testDegenerateRingProducesNoTriangles() {
        XCTAssertTrue(BubblePhysicsMetalRender.triangulate([.init(0, 0), .init(1, 0)]).isEmpty)
    }
}
