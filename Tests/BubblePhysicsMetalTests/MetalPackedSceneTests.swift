import XCTest
import Metal
import simd
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalPackedSceneTests: XCTestCase {
    func testStressSceneKeepsAllParticlesFiniteWithoutOverflow() throws {
        let (session, queue) = try makeSession(.stress)
        var resources: MetalFrameResources?

        for step in 0..<3 {
            resources = try runFrame(session, queue: queue, triangle: KinematicTriangleMotion.default.sample(time: Double(step) / 60, isPaused: false))
            let requiredContacts = resources?.contourContactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee ?? 0
            XCTAssertEqual(session.status, .ready, "Session failed after packed-scene step \(step); required contacts \(requiredContacts), current heuristic capacity \((resources?.particleCount ?? 0) * 8)")
        }

        let frame = try XCTUnwrap(resources)
        XCTAssertEqual(session.status, .ready)
        XCTAssertGreaterThan(frame.contourContactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee, 0)
        XCTAssertTrue(readParticles(frame).allSatisfy { particle in
            particle.position.x.isFinite && particle.position.y.isFinite &&
                particle.previousPosition.x.isFinite && particle.previousPosition.y.isFinite
        })
    }

    func testLargestCompressedBubbleCoexistsWithSmallBubbleContacts() throws {
        let seeds = PrototypeSceneFactory.seeds(for: .stress)
        let snapshot = MetalWorldSnapshot(world: try PrototypeSceneFactory.make(.stress))
        let largestIndex = try XCTUnwrap(seeds.firstIndex(where: { $0.value == 2048 }))
        let smallestIndex = try XCTUnwrap(seeds.firstIndex(where: { $0.value == 2 }))
        let largest = snapshot.bubbleRanges[largestIndex]
        let smallest = snapshot.bubbleRanges[smallestIndex]
        let (session, queue) = try makeSession(snapshot)

        let frame = try runFrame(session, queue: queue, triangle: KinematicTriangleMotion.default.sample(time: 0, isPaused: true))
        let particles = readParticles(frame)
        let largestPoints = boundary(largest, particles: particles)
        let smallestPoints = boundary(smallest, particles: particles)

        XCTAssertGreaterThan(largest.restArea, Float.pi * 375 * 375)
        XCTAssertTrue(largestPoints.allSatisfy {
            $0.x >= 0 && $0.x <= 375 && $0.y >= 0 && $0.y <= 812
        })
        XCTAssertTrue(smallestPoints.allSatisfy { $0.x.isFinite && $0.y.isFinite })
        XCTAssertGreaterThan(frame.contourContactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee, 0)
    }

    func testBubblesRefillSpaceAfterTriangleMovesAway() throws {
        let snapshot = MetalWorldSnapshot(world: try PrototypeSceneFactory.make(.inspection))
        let (session, queue) = try makeSession(snapshot)
        let occupied = KinematicTriangleMotion.default.sample(time: 0, isPaused: true)
        var frame: MetalFrameResources!
        for _ in 0..<12 { frame = try runFrame(session, queue: queue, triangle: occupied) }
        let clearanceBefore = meanClearanceNearTriangle(frame, center: occupied.position)

        let movedAway = KinematicTriangleMotion.default.sample(time: KinematicTriangleMotion.default.period / 2, isPaused: true)
        for _ in 0..<48 { frame = try runFrame(session, queue: queue, triangle: movedAway) }
        let clearanceAfter = meanClearanceNearTriangle(frame, center: occupied.position)

        XCTAssertLessThan(clearanceAfter, clearanceBefore)
    }

    private func makeSession(_ size: PrototypeSceneSize) throws -> (MetalSimulationSession, MTLCommandQueue) {
        try makeSession(MetalWorldSnapshot(world: PrototypeSceneFactory.make(size)))
    }

    private func makeSession(_ snapshot: MetalWorldSnapshot) throws -> (MetalSimulationSession, MTLCommandQueue) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        return (try MetalSimulationSession(snapshot: snapshot, device: device), try XCTUnwrap(device.makeCommandQueue()))
    }

    private func runFrame(_ session: MetalSimulationSession, queue: MTLCommandQueue, triangle: KinematicTriangleState) throws -> MetalFrameResources {
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let resources = try session.encodeFrame(input: .init(gravity: .zero, bounds: PrototypeSceneFactory.bounds, triangleState: triangle), commandBuffer: command)
        command.commit()
        command.waitUntilCompleted()
        XCTAssertEqual(command.status, .completed)
        return resources
    }

    private func readParticles(_ resources: MetalFrameResources) -> [MetalParticle] {
        let pointer = resources.particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: resources.particleCount)
        return Array(UnsafeBufferPointer(start: pointer, count: resources.particleCount))
    }

    private func boundary(_ range: MetalBubbleRange, particles: [MetalParticle]) -> [SIMD2<Float>] {
        (0..<Int(range.boundaryCount)).map { particles[Int(range.boundaryStart) + $0].position }
    }

    private func meanClearanceNearTriangle(_ resources: MetalFrameResources, center: Vector2) -> Float {
        let particles = readParticles(resources)
        let samples = stride(from: -30, through: 30, by: 10).flatMap { y in
            stride(from: -30, through: 30, by: 10).map { x in SIMD2<Float>(center.x + Float(x), center.y + Float(y)) }
        }
        let distances = samples.map { sample in particles.map { simd_distance(sample, $0.position) }.min() ?? .infinity }
        return distances.reduce(0, +) / Float(distances.count)
    }
}
