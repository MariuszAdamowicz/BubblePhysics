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
