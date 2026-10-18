import BubblePhysics
import XCTest

final class WorldTransactionTests: XCTestCase {
    func testFluentBuilderPreservesOriginalValueAndOperationOrder() throws {
        let original = WorldTransaction().setGlobalForce([0, -9])
        let extended = original.applyImpulse(to: ObjectID(rawValue: 42), impulse: [2, 0])
        XCTAssertEqual(original.operations, [.setGlobalForce([0, -9])])
        XCTAssertEqual(extended.operations, [
            .setGlobalForce([0, -9]), .applyImpulse(ObjectID(rawValue: 42), [2, 0])
        ])
    }
}
