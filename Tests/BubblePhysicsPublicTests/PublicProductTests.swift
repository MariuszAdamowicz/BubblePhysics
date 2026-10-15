import BubblePhysics
import XCTest

final class PublicProductTests: XCTestCase {
    func testGameProductExportsPublicFacade() {
        _ = BubbleWorld.self
        _ = WorldTransaction.self
        _ = WorldFrame.self
    }
}
