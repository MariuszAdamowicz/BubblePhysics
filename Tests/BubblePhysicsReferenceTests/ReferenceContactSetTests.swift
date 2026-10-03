import XCTest
@testable import BubblePhysicsReference

final class ReferenceContactSetTests: XCTestCase {
    func testNewContactActivatesOnlyAboveContactTolerance() {
        var set = ReferenceContactSet()
        var configuration = ReferenceConfiguration.default
        configuration.contactTolerance = 0.01

        set.update(candidates: [contact(id: 1, penetration: 0.005)], bubbles: [], segments: [], configuration: configuration)
        XCTAssertTrue(set.contacts.isEmpty)

        set.update(candidates: [contact(id: 1, penetration: 0.02)], bubbles: [], segments: [], configuration: configuration)
        XCTAssertEqual(set.contacts.map(\.id), [.init(rawValue: 1)])
    }

    func testExistingContactUsesSeparationHysteresis() {
        var set = ReferenceContactSet()
        var configuration = ReferenceConfiguration.default
        configuration.contactTolerance = 0.001
        configuration.separationTolerance = 0.01

        set.update(candidates: [contact(id: 9, penetration: 0.1)], bubbles: [], segments: [], configuration: configuration)
        set.update(candidates: [contact(id: 9, penetration: -0.005)], bubbles: [], segments: [], configuration: configuration)
        XCTAssertEqual(set.contacts.count, 1)
        XCTAssertEqual(set.contacts[0].age, 1)

        set.update(candidates: [contact(id: 9, penetration: -0.02)], bubbles: [], segments: [], configuration: configuration)
        XCTAssertTrue(set.contacts.isEmpty)
    }

    func testStableIdentityAndOrderingDoNotDependOnCandidateOrder() {
        var set = ReferenceContactSet()
        let candidates = [contact(id: 7, penetration: 1), contact(id: 2, penetration: 1), contact(id: 5, penetration: 1)]

        set.update(candidates: candidates, bubbles: [], segments: [], configuration: .default)
        let first = set.contacts
        set.update(candidates: Array(candidates.reversed()), bubbles: [], segments: [], configuration: .default)

        XCTAssertEqual(set.contacts.map(\.id), [.init(rawValue: 2), .init(rawValue: 5), .init(rawValue: 7)])
        XCTAssertEqual(set.contacts.map(\.id), first.map(\.id))
        XCTAssertEqual(set.contacts.map(\.age), [1, 1, 1])
    }

    func testSignedGeometryCandidateKeepsExistingContactAcrossTinyGap() throws {
        let first = try ReferenceBubble(id: .init(rawValue: 1), center: .zero, mass: 1, targetRadius: 10)
        let touching = try ReferenceBubble(id: .init(rawValue: 2), center: .init(x: 19.999, y: 0), mass: 1, targetRadius: 10)
        var set = ReferenceContactSet(contacts: [try XCTUnwrap(
            ReferenceDiscreteContactGenerator.bubbleBubble(first, touching)
        )])
        let separated = try ReferenceBubble(id: .init(rawValue: 2), center: .init(x: 20.001, y: 0), mass: 1, targetRadius: 10)

        let signed = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(first, separated)
        set.update(candidates: [signed], bubbles: [first, separated], segments: [], configuration: .default)

        XCTAssertEqual(set.contacts.count, 1)
        XCTAssertLessThan(set.contacts[0].penetration, 0)
    }

    func testExistingContactPreservesStressState() {
        var previous = contact(id: 12, penetration: 2)
        previous.compressionA = 1.25
        previous.compressionB = 0.75
        previous.pressure = 42
        previous.effectiveStiffness = 9
        var set = ReferenceContactSet(contacts: [previous])

        set.update(candidates: [contact(id: 12, penetration: 1)], bubbles: [], segments: [], configuration: .default)

        XCTAssertEqual(set.contacts[0].compressionA, 1.25)
        XCTAssertEqual(set.contacts[0].compressionB, 0.75)
        XCTAssertEqual(set.contacts[0].pressure, 42)
        XCTAssertEqual(set.contacts[0].effectiveStiffness, 9)
    }

    private func contact(id: UInt64, penetration: Float) -> ReferenceContact {
        ReferenceContact(
            id: .init(rawValue: id),
            kind: .bubbleBubble,
            bubbleA: .init(rawValue: 1),
            bubbleB: .init(rawValue: 2),
            normal: .init(x: 1, y: 0),
            pointQ: .zero,
            penetration: penetration
        )
    }
}
