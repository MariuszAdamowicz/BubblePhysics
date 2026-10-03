import XCTest
@testable import BubblePhysicsReference

final class ContourGeneratorTests: XCTestCase {
    func testSmallBubbleCreatesOnlyFiniteSharedChordOnLargeBubble() throws {
        let large = try ReferenceBubble(
            id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 10
        )
        let small = try ReferenceBubble(
            id: .init(rawValue: 2), center: .init(x: 10, y: 0), mass: 1, targetRadius: 3
        )
        var contact = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(large, small)
        contact.pointQ = .init(x: 9.55, y: 0)
        contact.contourHalfLength = 2.97
        contact.pressure = 100

        let points = ReferenceContourGenerator.points(
            for: large, contacts: [contact], configuration: configuration()
        )
        let flat = points.filter { abs($0.x - 9.55) < 0.02 }

        XCTAssertFalse(flat.isEmpty)
        XCTAssertLessThanOrEqual(flat.map { abs($0.y) }.max() ?? 100, 3.05)
        XCTAssertGreaterThan(points.filter { abs($0.y) > 3.2 }.map(\.x).max() ?? 0, 9.15)
    }
    func testVertexIndentationDoesNotExtendFiniteEdgesIntoAFullWedge() throws {
        let bubble = try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 0, y: -75), mass: 1, targetRadius: 78
        )
        let vertices = [
            ReferenceVector2(x: -46, y: 34), .init(x: 46, y: 34), .init(x: 0, y: -52),
        ]
        let edges = vertices.indices.map { index in
            ReferenceSegment.staticSegment(
                id: .init(rawValue: index + 1), a: vertices[index],
                b: vertices[(index + 1) % vertices.count], ownerID: 100
            )
        }
        let contacts = edges.compactMap {
            ReferenceDiscreteContactGenerator.bubbleSegment(bubble, $0)
        }

        let points = ReferenceContourGenerator.points(
            for: bubble, contacts: contacts, segments: edges, configuration: configuration()
        )

        XCTAssertLessThan(points.map(\.x).min() ?? 0, -75)
        XCTAssertGreaterThan(points.map(\.x).max() ?? 0, 75)
        XCTAssertLessThan(points.map(\.y).min() ?? 0, -150)
        let inside = points.filter { isInsideTriangle($0, vertices) }
        XCTAssertTrue(inside.isEmpty, "inside points: \(inside)")
    }
    func testPolygonVertexContactUsesBothRealEdgePlanesInsteadOfTangentAtVertex() throws {
        let bubble = try ReferenceBubble(
            id: .init(rawValue: 1), center: .init(x: 6, y: 6), mass: 1, targetRadius: 10
        )
        let edges = [
            ReferenceSegment.staticSegment(
                id: .init(rawValue: 10), a: .init(x: 0, y: 0), b: .init(x: 12, y: 0)
            ),
            ReferenceSegment.staticSegment(
                id: .init(rawValue: 11), a: .init(x: 0, y: 12), b: .init(x: 0, y: 0)
            ),
        ]
        let contacts = edges.map {
            ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(bubble, $0)
        }

        let points = ReferenceContourGenerator.points(
            for: bubble, contacts: contacts, segments: edges, configuration: .default
        )

        XCTAssertTrue(points.allSatisfy { $0.x >= -0.001 && $0.y >= -0.001 })
        XCTAssertTrue(points.contains { abs($0.x) < 0.01 && $0.y > 0.5 })
        XCTAssertTrue(points.contains { abs($0.y) < 0.01 && $0.x > 0.5 })
    }
    func testNoContactsProduceExactNaturalCircle() throws {
        let bubble = try makeBubble(center: .init(x: 3, y: -2), radius: 10)

        let points = ReferenceContourGenerator.points(for: bubble, contacts: [], configuration: configuration())

        XCTAssertGreaterThanOrEqual(points.count, 32)
        for point in points {
            XCTAssertEqual((point - bubble.center).length, 10, accuracy: 1e-4)
        }
    }

    func testFlatContactCreatesBroadStraightSection() throws {
        let bubble = try makeBubble(radius: 10)
        let contact = segmentContact(id: 1, pointQ: .init(x: 8, y: 0), inward: .init(x: -1, y: 0), compression: 2)

        let points = ReferenceContourGenerator.points(for: bubble, contacts: [contact], configuration: configuration())
        let flat = points.filter { abs($0.y) < 3.5 && $0.x > 7.9 }

        XCTAssertGreaterThanOrEqual(flat.count, 3)
        XCTAssertTrue(flat.allSatisfy { abs($0.x - 8) < 1e-3 })
    }

    func testCornerRoundsSeveralSamplesWithoutCollapsingRadius() throws {
        let bubble = try makeBubble(radius: 10)
        let contacts = [
            segmentContact(id: 1, pointQ: .init(x: 7, y: 0), inward: .init(x: -1, y: 0), compression: 3),
            segmentContact(id: 2, pointQ: .init(x: 0, y: 7), inward: .init(x: 0, y: -1), compression: 3)
        ]

        let points = ReferenceContourGenerator.points(for: bubble, contacts: contacts, configuration: configuration())
        let corner = points.filter { $0.x > 4 && $0.y > 4 }

        XCTAssertGreaterThanOrEqual(corner.count, 3)
        XCTAssertTrue(corner.allSatisfy { $0.length > 5 && $0.x <= 7.001 && $0.y <= 7.001 })
        XCTAssertTrue(corner.contains { $0.x < 6.9 && $0.y < 6.9 })
    }

    func testOppositeContactsChooseEnvelopeInsteadOfSummingHole() throws {
        let bubble = try makeBubble(radius: 10)
        let contacts = [
            segmentContact(id: 1, pointQ: .init(x: -8, y: 0), inward: .init(x: 1, y: 0), compression: 2),
            segmentContact(id: 2, pointQ: .init(x: 8, y: 0), inward: .init(x: -1, y: 0), compression: 2)
        ]

        let points = ReferenceContourGenerator.points(for: bubble, contacts: contacts, configuration: configuration())

        XCTAssertGreaterThan(points.map(\.length).min() ?? 0, 7.5)
        XCTAssertLessThanOrEqual(points.map(\.x).max() ?? 100, 8.001)
        XCTAssertGreaterThanOrEqual(points.map(\.x).min() ?? -100, -8.001)
    }

    func testRemovingContactImmediatelyRestoresCircle() throws {
        let bubble = try makeBubble(radius: 10)
        let contact = segmentContact(id: 1, pointQ: .init(x: 7, y: 0), inward: .init(x: -1, y: 0), compression: 3)
        let compressed = ReferenceContourGenerator.points(for: bubble, contacts: [contact], configuration: configuration())

        let restored = ReferenceContourGenerator.points(for: bubble, contacts: [], configuration: configuration())

        XCTAssertLessThan(compressed.map(\.x).max() ?? 10, 10)
        XCTAssertTrue(restored.allSatisfy { abs($0.length - 10) < 1e-4 })
    }

    func testContourPointsStayOutsideRigidTriangle() throws {
        let bubble = try makeBubble(center: .init(x: 5, y: 5), radius: 6)
        let contacts = [
            segmentContact(id: 1, pointQ: .init(x: 3, y: 3), inward: .init(x: 1, y: 1), compression: 2),
            segmentContact(id: 2, pointQ: .init(x: 7, y: 3), inward: .init(x: -1, y: 1), compression: 2),
            segmentContact(id: 3, pointQ: .init(x: 5, y: 7), inward: .init(x: 0, y: -1), compression: 2)
        ]
        let triangle = [ReferenceVector2(x: 3, y: 3), .init(x: 7, y: 3), .init(x: 5, y: 7)]

        let points = ReferenceContourGenerator.points(for: bubble, contacts: contacts, configuration: configuration())

        XCTAssertFalse(points.contains { isInsideTriangle($0, triangle) })
    }

    private func configuration() -> ReferenceConfiguration {
        var value = ReferenceConfiguration.default
        value.maxContourSegmentLength = 1
        value.contourSurfaceTension = 20
        return value
    }

    private func makeBubble(center: ReferenceVector2 = .zero, radius: Float) throws -> ReferenceBubble {
        try ReferenceBubble(id: .init(rawValue: 1), center: center, mass: 1, targetRadius: radius)
    }

    private func segmentContact(
        id: UInt64,
        pointQ: ReferenceVector2,
        inward: ReferenceVector2,
        compression: Float
    ) -> ReferenceContact {
        .init(
            id: .init(rawValue: id), kind: .bubbleSegment,
            bubbleA: .init(rawValue: 1), segment: .init(rawValue: Int(id)),
            normal: inward.normalized(), pointQ: pointQ, penetration: compression,
            accumulatedCompression: compression, compressionA: compression,
            pressure: 30 * compression, effectiveStiffness: 30
        )
    }

    private func isInsideTriangle(_ point: ReferenceVector2, _ triangle: [ReferenceVector2]) -> Bool {
        let signs = triangle.indices.map { index in
            let a = triangle[index]
            let b = triangle[(index + 1) % triangle.count]
            return (b - a).cross(point - a)
        }
        return signs.allSatisfy { $0 > 1e-5 } || signs.allSatisfy { $0 < -1e-5 }
    }
}
