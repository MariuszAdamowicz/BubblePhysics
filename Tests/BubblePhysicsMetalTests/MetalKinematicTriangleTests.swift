import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalKinematicTriangleTests: XCTestCase {
    func testPersistentFrameAppliesMovingTriangleAndRemainsFinite() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let world = try PrototypeSceneFactory.make(.inspection)
        let snapshot = MetalWorldSnapshot(world: world)
        let session = try MetalSimulationSession(snapshot: snapshot, device: device)
        let state = KinematicTriangleMotion.default.sample(time: 1, isPaused: false)
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let resources = try session.encodeFrame(input: .init(gravity: .zero, bounds: PrototypeSceneFactory.bounds, triangleState: state), commandBuffer: command)
        command.commit(); await command.completed()

        XCTAssertEqual(command.status, .completed)
        XCTAssertEqual(session.status, .ready)
        let particles = resources.particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: resources.particleCount)
        XCTAssertTrue((0..<resources.particleCount).allSatisfy { particles[$0].position.x.isFinite && particles[$0].position.y.isFinite })
    }
}
