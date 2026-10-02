import XCTest
@testable import BubblePhysics

final class RadialBubbleContactTests: XCTestCase {
    func testBroadPhaseReturnsOnlyOverlappingSweptAABBsInStableOrder() throws {
        var first = bubble(id: 30, center: Vector2(x: 0, y: 0), radius: 5)
        first.body.linearVelocity = Vector2(x: 20, y: 0)
        let second = bubble(id: 10, center: Vector2(x: 25, y: 0), radius: 5)
        let far = bubble(id: 20, center: Vector2(x: 100, y: 100), radius: 5)
        let world = try RadialWorldState(bubbles: [first, far, second])

        XCTAssertEqual(
            RadialBubbleBroadPhase.candidates(in: world, deltaTime: 1),
            [RadialBubblePair(firstID: BubbleID(rawValue: 10), secondID: BubbleID(rawValue: 30))]
        )
    }

    func testCrossingSegmentsProduceBarycentricPairContact() {
        var first = bubble(id: 1, center: Vector2(x: 0, y: 0), radius: 10)
        first.body.angle = .pi / 8
        let second = bubble(id: 2, center: Vector2(x: 15, y: 0), radius: 10)

        let contacts = RadialBubbleContacts.generate(first: first, second: second)

        XCTAssertTrue(contacts.contains {
            $0.firstBarycentric > 0 && $0.firstBarycentric < 1
                && $0.secondBarycentric > 0 && $0.secondBarycentric < 1
        })
    }

    func testSmallBubbleContainedByLargeBubbleProducesContacts() {
        let small = bubble(id: 1, center: Vector2(x: 3, y: 0), radius: 2)
        let large = bubble(id: 2, center: .zero, radius: 20)

        let contacts = RadialBubbleContacts.generate(first: small, second: large)

        XCTAssertFalse(contacts.isEmpty)
        XCTAssertTrue(contacts.allSatisfy { $0.penetration > 0 })
    }

    func testPairLoadsAreEqualAndOpposite() {
        let first = bubble(id: 1, center: Vector2(x: 0, y: 0), radius: 10)
        let second = bubble(id: 2, center: Vector2(x: 15, y: 0), radius: 10)
        let contacts = RadialBubbleContacts.generate(first: first, second: second)

        let loads = RadialBubbleContacts.reduce(contacts: contacts, first: first, second: second)

        XCTAssertEqual(loads.first.force.x, -loads.second.force.x, accuracy: 1e-5)
        XCTAssertEqual(loads.first.force.y, -loads.second.force.y, accuracy: 1e-5)
    }

    func testPairLoadDoesNotCreateNetLinearMomentum() {
        var first = bubble(id: 1, center: Vector2(x: 0, y: 0), radius: 10)
        var second = bubble(id: 2, center: Vector2(x: 15, y: 2), radius: 10)
        first.body.linearVelocity = Vector2(x: 4, y: 1)
        second.body.linearVelocity = Vector2(x: -2, y: -1)
        let contacts = RadialBubbleContacts.generate(first: first, second: second)

        let loads = RadialBubbleContacts.reduce(contacts: contacts, first: first, second: second)
        let net = loads.first.force + loads.second.force

        XCTAssertEqual(net.x, 0, accuracy: 1e-5)
        XCTAssertEqual(net.y, 0, accuracy: 1e-5)
    }

    private func bubble(id: Int, center: Vector2, radius: Float) -> RadialBubbleState {
        var state = RadialBubbleState.collapsed(
            id: BubbleID(rawValue: id), center: center, targetRadius: radius,
            maxSegmentLength: radius, mass: 1
        )
        state.birthProgress = 1
        for index in state.sensors.indices {
            state.sensors[index].length = radius
            state.sensors[index].targetLength = radius
        }
        return state
    }
}
