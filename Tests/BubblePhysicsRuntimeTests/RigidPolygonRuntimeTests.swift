import BubblePhysics
import XCTest

@MainActor
final class RigidPolygonRuntimeTests: XCTestCase {
    func testDynamicAndMotorPolygonTransactionsCommitAndAdvance() async throws {
        for role: MotionRole in [.dynamic, .motorDriven] {
            let world = try BubbleWorld(configuration: WorldConfiguration(simulationRegion:
                WorldRectangle(min: [-10,-10], max: [10,10]), fixedTimeStep: 0.125))
            let id = ObjectID(rawValue: UInt64.max)
            let token = world.submit(try WorldTransaction()
                .updatePhysicsMaterial(.init(rawValue: 1), material: PhysicsMaterial(kind: .polygon))
                .updateRenderStyle(.init(rawValue: 1), style: RenderStyle())
                .add(.polygon(PolygonDescriptor(id: id, vertices: [[-1,-1],[1,-1],[1,1],[-1,1]],
                    velocity: [2,0], angularVelocity: 1, motionRole: role,
                    physicsMaterialID: .init(rawValue: 1), renderStyleID: .init(rawValue: 1)))))
            let frame = await world.advance(by: 0.125)
            XCTAssertEqual(frame.transactionReceipts.first?.token, token)
            XCTAssertEqual(frame.transactionReceipts.first?.createdObjectIDs, [id])
            XCTAssertNil(world.diagnostics.lastAdvanceIssue)
            XCTAssertEqual(frame.stepIndex, 1)
        }
    }
}
