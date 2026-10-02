import XCTest
@testable import BubblePhysicsReference

final class ReferenceBroadPhaseTests: XCTestCase {
    func testAllImplementationsMatchBruteForceAcrossRepresentativeScenes() {
        let scenes: [[ReferenceProxy]] = [
            [],
            [proxy(0, x: 0, y: 0, radius: 1)],
            (0..<4).map { proxy($0, x: 0, y: 0, radius: 2) },
            largeObjectScene(),
            mixedScene(count: 300)
        ]

        for scene in scenes {
            var oracle = BruteForceBroadPhase()
            let expected = oracle.candidatePairs(for: scene)
            var implementations: [any ReferenceBroadPhase] = [
                SweepAndPruneBroadPhase(),
                AABBTreeBroadPhase()
            ]

            for index in implementations.indices {
                let actual = implementations[index].candidatePairs(for: Array(scene.reversed()))
                XCTAssertEqual(actual, expected)
                XCTAssertEqual(Set(actual).count, actual.count)
                XCTAssertEqual(actual, actual.sorted())
            }
        }
    }

    func testIdenticalBoundsProduceEveryUniquePair() {
        let scene = (0..<4).map { proxy($0, x: 0, y: 0, radius: 2) }
        var broadPhase = SweepAndPruneBroadPhase()

        let pairs = broadPhase.candidatePairs(for: scene)

        XCTAssertEqual(pairs.count, 6)
        XCTAssertEqual(Set(pairs).count, 6)
    }

    func testMovingProxiesRemainConsistentAcrossCalls() {
        var scene = mixedScene(count: 300)
        var sweep = SweepAndPruneBroadPhase()
        var tree = AABBTreeBroadPhase()
        _ = sweep.candidatePairs(for: scene)
        _ = tree.candidatePairs(for: scene)

        for index in scene.indices where index.isMultiple(of: 3) {
            scene[index].bounds.minimum.x += 17
            scene[index].bounds.maximum.x += 17
            scene[index].bounds.minimum.y -= 9
            scene[index].bounds.maximum.y -= 9
        }
        var oracle = BruteForceBroadPhase()
        let expected = oracle.candidatePairs(for: scene)

        XCTAssertEqual(sweep.candidatePairs(for: scene), expected)
        XCTAssertEqual(tree.candidatePairs(for: scene), expected)
    }

    private func largeObjectScene() -> [ReferenceProxy] {
        var result = [
            ReferenceProxy(id: .init(rawValue: 0), bounds: .init(minimum: .init(x: -1_000, y: -1_000), maximum: .init(x: 1_000, y: 1_000)))
        ]
        result.append(contentsOf: (1...20).map { proxy($0, x: Float($0 * 10), y: 0, radius: 1) })
        return result
    }

    private func mixedScene(count: Int) -> [ReferenceProxy] {
        (0..<count).map { index in
            let column = index % 30
            let row = index / 30
            let radius = Float(1 + (index % 9))
            return proxy(index, x: Float(column * 7), y: Float(row * 7), radius: radius)
        }
    }

    private func proxy(_ id: Int, x: Float, y: Float, radius: Float) -> ReferenceProxy {
        ReferenceProxy(
            id: .init(rawValue: id),
            bounds: .init(
                minimum: .init(x: x - radius, y: y - radius),
                maximum: .init(x: x + radius, y: y + radius)
            )
        )
    }
}
