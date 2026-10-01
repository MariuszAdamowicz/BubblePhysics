import XCTest
import Metal
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalGrabControllerTests: XCTestCase {
    func testCPUReferencePickingChoosesTopmostOverlappingBubbleAndNearestBoundary() {
        let particles = [
            particle(0, 0), particle(-2, -2), particle(2, -2), particle(2, 2), particle(-2, 2),
            particle(0, 0), particle(-1, -1), particle(1, -1), particle(1, 1), particle(-1, 1)
        ]
        let ranges = [range(id: 10, center: 0, boundary: 1), range(id: 20, center: 5, boundary: 6)]

        let selection = MetalGrabController.referencePick(at: .zero, particles: particles, ranges: ranges)

        XCTAssertEqual(selection?.bubbleID, 20)
        XCTAssertEqual(selection?.particleIndex, 6)
        XCTAssertNil(MetalGrabController.referencePick(at: SIMD2(20, 20), particles: particles, ranges: ranges))
    }

    func testMoveFiltersJumpAndCapsCorrection() throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let controller = try MetalGrabController(device: device, maximumTargetSpeed: 100, targetSmoothing: 0.5, maximumCorrection: 1.5)
        controller.installSelectionForTesting(particleIndex: 7, target: .zero, timestamp: 0)

        controller.move(to: SIMD2(100, 0), timestamp: 0.1)

        XCTAssertEqual(controller.filteredTarget.x, 5, accuracy: 0.001)
        XCTAssertEqual(controller.maximumCorrection, 1.5)
        controller.end()
        XCTAssertFalse(controller.isActive)
    }

    func testGPUPickingBeginsOnlyInsideBubble() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let snapshot = MetalWorldSnapshot(world: try PrototypeSceneFactory.make(.inspection))
        let session = try MetalSimulationSession(snapshot: snapshot, device: device)
        let resources = try session.encodeFrame(input: .init(), commandBuffer: try XCTUnwrap(queue.makeCommandBuffer()))
        let controller = try MetalGrabController(device: device)

        let hit = try await controller.begin(at: SIMD2(48, 72), resources: resources, timestamp: 0)
        XCTAssertTrue(hit)
        controller.end()
        let miss = try await controller.begin(at: SIMD2(-100, -100), resources: resources, timestamp: 1)
        XCTAssertFalse(miss)
    }

    private func particle(_ x: Float, _ y: Float) -> MetalParticle {
        MetalParticle(position: SIMD2(x, y), previousPosition: SIMD2(x, y), inverseMass: 1, bubbleIndex: 0)
    }

    private func range(id: UInt32, center: UInt32, boundary: UInt32) -> MetalBubbleRange {
        MetalBubbleRange(id: id, centerIndex: center, boundaryStart: boundary, boundaryCount: 4, restArea: 16, distanceConstraintStart: 0, distanceConstraintCount: 0)
    }
}
