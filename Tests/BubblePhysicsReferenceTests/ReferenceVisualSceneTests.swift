import XCTest
@testable import BubblePhysicsReference

final class ReferenceVisualSceneTests: XCTestCase {
    func testFactoryBuildsReadableBubblesFourWallsAndOnePolygon() throws {
        let scene = try ReferenceVisualSceneFactory.make()

        XCTAssertEqual(scene.world.bubbles.count, 6)
        XCTAssertEqual(scene.world.segments.count, 7)
        XCTAssertEqual(scene.world.segments.prefix(4).compactMap(\.collisionMode.allowedSide).count, 4)
        XCTAssertTrue(scene.world.segments.suffix(3).allSatisfy { $0.collisionMode == .twoSided })
        XCTAssertEqual(Set(scene.world.segments.suffix(3).compactMap(\.ownerID)), [scene.triangleOwnerID])

        let radii = scene.world.bubbles.map(\.targetRadius)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(radii.min()), 28)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(radii.max()), 90)
        XCTAssertGreaterThanOrEqual(Set(radii).count, 6)

        let expected: [Int: Float] = [2: 28, 8: 42, 32: 54, 128: 62, 512: 78, 2048: 96]
        XCTAssertEqual(Set(scene.valuesByBubbleID.values), Set(expected.keys))
        for bubble in scene.world.bubbles {
            XCTAssertEqual(bubble.targetRadius, expected[scene.valuesByBubbleID[bubble.id]!]!)
        }
        let ordered = scene.world.bubbles.sorted { scene.valuesByBubbleID[$0.id]! < scene.valuesByBubbleID[$1.id]! }
        XCTAssertTrue(zip(ordered, ordered.dropFirst()).allSatisfy { $0.targetRadius <= $1.targetRadius })

        for first in scene.world.bubbles.indices {
            for second in scene.world.bubbles.indices where second > first {
                let penetration = scene.world.bubbles[first].targetRadius + scene.world.bubbles[second].targetRadius
                    - (scene.world.bubbles[second].center - scene.world.bubbles[first].center).length
                XCTAssertLessThanOrEqual(penetration, 2.001)
            }
        }
        let triangle = ReferenceVisualSceneFactory.triangleVertices(localVertices: scene.triangleLocalVertices, at: 0)
        XCTAssertTrue(scene.world.bubbles.allSatisfy { !pointInTriangle($0.center, triangle) })
    }

    private func pointInTriangle(_ point: ReferenceVector2, _ vertices: [ReferenceVector2]) -> Bool {
        let signs = vertices.indices.map { index in
            (vertices[(index + 1) % 3] - vertices[index]).cross(point - vertices[index])
        }
        return signs.allSatisfy { $0 >= 0 } || signs.allSatisfy { $0 <= 0 }
    }
}
