import XCTest
@testable import BubblePhysics

final class BubbleContactTests: XCTestCase {
    func testSeparatedBubblesProduceNoContacts() {
        let contacts = BubbleContactGenerator.contacts(between: square(id: 1, center: Vector2(x: 0, y: 0), halfExtent: 5), and: square(id: 2, center: Vector2(x: 30, y: 0), halfExtent: 5))

        XCTAssertTrue(contacts.isEmpty)
    }

    func testCrossingEdgesProduceContactWhenNoVertexIsContained() {
        let horizontal = BubbleTopology(id: BubbleID(rawValue: 1), center: .zero, restArea: 40, boundaryPoints: [
            Vector2(x: -10, y: -1), Vector2(x: 10, y: -1), Vector2(x: 10, y: 1), Vector2(x: -10, y: 1)
        ])
        let vertical = BubbleTopology(id: BubbleID(rawValue: 2), center: .zero, restArea: 40, boundaryPoints: [
            Vector2(x: -1, y: -10), Vector2(x: 1, y: -10), Vector2(x: 1, y: 10), Vector2(x: -1, y: 10)
        ])

        XCTAssertFalse(BubbleContactGenerator.contacts(between: horizontal, and: vertical).isEmpty)
    }

    func testContainedVertexProducesOutwardContact() {
        let outer = square(id: 1, center: .zero, halfExtent: 10)
        let inner = square(id: 2, center: Vector2(x: 8, y: 0), halfExtent: 3)

        let contacts = BubbleContactGenerator.contacts(between: outer, and: inner)

        XCTAssertTrue(contacts.contains { $0.penetration > 0 })
    }

    func testIndexedContactsMatchTopologyContacts() {
        let first = square(id: 1, center: Vector2(x: 0, y: 0), halfExtent: 5)
        let second = square(id: 2, center: Vector2(x: 7, y: 0), halfExtent: 5)
        var particles = ParticleStore()
        let firstIndices = first.boundaryPoints.map { particles.append(Particle(position: $0)) }
        let secondIndices = second.boundaryPoints.map { particles.append(Particle(position: $0)) }

        let topologyContacts = BubbleContactGenerator.contacts(between: first, and: second)
        let indexedContacts = BubbleContactGenerator.contacts(
            firstCenter: first.center,
            firstBoundaryIndices: firstIndices,
            secondCenter: second.center,
            secondBoundaryIndices: secondIndices,
            particles: particles.particles
        )

        XCTAssertEqual(indexedContacts, topologyContacts)
    }

    func testOverlappingBubblesSeparateWithoutLosingRestArea() {
        var world = BubbleWorld(configuration: .default)
        let first = world.addBubble(center: Vector2(x: 0, y: 0), restArea: .pi * 100)
        let second = world.addBubble(center: Vector2(x: 12, y: 0), restArea: .pi * 100)
        let initialDistance = distance(world.bubble(first)!.center, world.bubble(second)!.center)

        for _ in 0..<30 { world.step() }

        XCTAssertGreaterThan(distance(world.bubble(first)!.center, world.bubble(second)!.center), initialDistance)
        XCTAssertEqual(world.currentArea(of: first)!, .pi * 100, accuracy: 3)
        XCTAssertEqual(world.currentArea(of: second)!, .pi * 100, accuracy: 3)
    }

    func testDenseGroupRemainsFiniteAndMayCompressAcrossManySolverSteps() {
        var world = BubbleWorld(configuration: .default)
        var identifiers: [BubbleID] = []
        for row in 0..<4 {
            for column in 0..<4 {
                identifiers.append(world.addBubble(
                    center: Vector2(x: Float(column) * 7, y: Float(row) * 7),
                    restArea: .pi * 25
                ))
            }
        }

        for _ in 0..<120 { world.step() }

        var compressedCount = 0
        for id in identifiers {
            XCTAssertFalse(world.bubble(id)!.boundaryPoints.contains { !$0.x.isFinite || !$0.y.isFinite })
            let area = world.currentArea(of: id)!
            XCTAssertGreaterThan(area, 0)
            if area < .pi * 25 - 3 { compressedCount += 1 }
        }
        XCTAssertGreaterThan(compressedCount, 0)
    }

    private func square(id: Int, center: Vector2, halfExtent: Float) -> BubbleTopology {
        BubbleTopology(id: BubbleID(rawValue: id), center: center, restArea: halfExtent * halfExtent * 4, boundaryPoints: [
            Vector2(x: center.x - halfExtent, y: center.y - halfExtent),
            Vector2(x: center.x + halfExtent, y: center.y - halfExtent),
            Vector2(x: center.x + halfExtent, y: center.y + halfExtent),
            Vector2(x: center.x - halfExtent, y: center.y + halfExtent)
        ])
    }

    private func distance(_ first: Vector2, _ second: Vector2) -> Float {
        let delta = first - second
        return (delta.dot(delta)).squareRoot()
    }
}
