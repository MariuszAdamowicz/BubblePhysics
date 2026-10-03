import XCTest
@testable import BubblePhysicsReference

final class DiscreteContactGeneratorTests: XCTestCase {
    func testBubblePairProducesOneContactWithPenetration() throws {
        let a = try bubble(id: 1, x: 0, y: 0, radius: 10)
        let b = try bubble(id: 2, x: 15, y: 0, radius: 10)

        let contact = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleBubble(a, b))

        XCTAssertEqual(contact.penetration, 5, accuracy: 0.0001)
        XCTAssertEqual(contact.normal, ReferenceVector2(x: 1, y: 0))
        XCTAssertEqual(contact.bubbleA, a.id)
        XCTAssertEqual(contact.bubbleB, b.id)
    }

    func testSegmentContactUsesInteriorQ() throws {
        let bubble = try self.bubble(id: 1, x: 5, y: 2, radius: 3)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 4),
            a: .init(x: 0, y: 0),
            b: .init(x: 10, y: 0),
            collisionMode: .oneSided(allowedSide: 1)
        )

        let contact = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment))

        XCTAssertEqual(contact.pointQ, ReferenceVector2(x: 5, y: 0))
        XCTAssertEqual(contact.penetration, 1, accuracy: 0.0001)
        XCTAssertEqual(contact.normal, ReferenceVector2(x: 0, y: 1))
    }

    func testSegmentContactUsesEndpointQ() throws {
        let bubble = try self.bubble(id: 1, x: -1, y: 0, radius: 2)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 4),
            a: .init(x: 0, y: 0),
            b: .init(x: 10, y: 0),
            collisionMode: .twoSided
        )

        let contact = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment))

        XCTAssertEqual(contact.pointQ, segment.currentA)
        XCTAssertEqual(contact.penetration, 1, accuracy: 0.0001)
        XCTAssertEqual(contact.normal, ReferenceVector2(x: -1, y: 0))
        XCTAssertNil(contact.allowedSide)
    }

    func testOneSidedSegmentAlwaysUsesAllowedNormal() throws {
        let bubble = try self.bubble(id: 1, x: 5, y: -2, radius: 3)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 4),
            a: .init(x: 0, y: 0),
            b: .init(x: 10, y: 0),
            collisionMode: .oneSided(allowedSide: 1)
        )

        let contact = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment))

        XCTAssertEqual(contact.normal, ReferenceVector2(x: 0, y: 1))
        XCTAssertEqual(contact.allowedSide, 1)
    }

    func testTwoSidedSegmentNormalPointsFromQToCenter() throws {
        let bubble = try self.bubble(id: 1, x: 5, y: -2, radius: 3)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 4),
            a: .init(x: 0, y: 0),
            b: .init(x: 10, y: 0),
            collisionMode: .twoSided
        )

        let contact = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment))

        XCTAssertEqual(contact.normal, ReferenceVector2(x: 0, y: -1))
        XCTAssertNil(contact.allowedSide)
    }

    func testTwoSidedCoincidenceUsesDeterministicFiniteNormal() throws {
        let bubble = try self.bubble(id: 1, x: 5, y: 0, radius: 3)
        let segment = ReferenceSegment.staticSegment(
            id: .init(rawValue: 4),
            a: .init(x: 0, y: 0),
            b: .init(x: 10, y: 0),
            collisionMode: .twoSided
        )

        let first = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment))
        let second = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleSegment(bubble, segment))

        XCTAssertEqual(first.normal, second.normal)
        XCTAssertTrue(first.normal.isFinite)
        XCTAssertEqual(first.normal.length, 1, accuracy: 0.0001)
    }

    func testCoincidentCentersUseDeterministicFiniteNormal() throws {
        let a = try bubble(id: 1, x: 0, y: 0, radius: 10)
        let b = try bubble(id: 2, x: 0, y: 0, radius: 10)

        let first = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleBubble(a, b))
        let second = try XCTUnwrap(ReferenceDiscreteContactGenerator.bubbleBubble(a, b))

        XCTAssertEqual(first.normal, second.normal)
        XCTAssertEqual(first.normal, ReferenceVector2(x: 1, y: 0))
        XCTAssertTrue(first.normal.isFinite)
        XCTAssertEqual(first.normal.length, 1, accuracy: 0.0001)
    }

    func testNearlyCoincidentCentersProduceFiniteDeterministicGeometryAndStressState() throws {
        let a = try bubble(id: 1, x: 0, y: 0, radius: 10)
        let b = try bubble(id: 2, x: 0.00000001, y: 0, radius: 10)

        let first = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(a, b)
        let second = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(a, b)

        XCTAssertEqual(first.normal, second.normal)
        XCTAssertTrue(first.normal.isFinite)
        XCTAssertTrue(first.penetration.isFinite)
        XCTAssertTrue(first.compressionA.isFinite)
        XCTAssertTrue(first.compressionB.isFinite)
        XCTAssertTrue(first.pressure.isFinite)
        XCTAssertTrue(first.effectiveStiffness.isFinite)
    }

    private func bubble(id: Int, x: Float, y: Float, radius: Float) throws -> ReferenceBubble {
        try ReferenceBubble(
            id: .init(rawValue: id),
            center: .init(x: x, y: y),
            mass: 1,
            targetRadius: radius
        )
    }
}
