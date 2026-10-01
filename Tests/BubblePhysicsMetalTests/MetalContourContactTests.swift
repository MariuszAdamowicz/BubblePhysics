import Metal
import simd
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalContourContactTests: XCTestCase {
    func testGPUContactCountMatchesCPUForContainedPointAndConcaveContour() throws {
        let first = [Vector2(x: 0.25, y: 0.25), Vector2(x: 0.75, y: 0.25), Vector2(x: 0.25, y: 0.75)]
        let concave = [
            Vector2(x: 0, y: 0), Vector2(x: 4, y: 0), Vector2(x: 4, y: 1),
            Vector2(x: 1, y: 1), Vector2(x: 1, y: 4), Vector2(x: 0, y: 4)
        ]

        let result = try runFrame(first: first, second: concave)

        XCTAssertEqual(result.contactCount, ContourContactReference.contacts(first: first, second: concave).count)
    }

    func testGPUDetectsCrossingOnlyContact() throws {
        let horizontal = rectangle(-2, -0.5, 2, 0.5)
        let vertical = rectangle(-0.5, -2, 0.5, 2)

        let result = try runFrame(first: horizontal, second: vertical)

        XCTAssertEqual(result.contactCount, ContourContactReference.contacts(first: horizontal, second: vertical).count)
        XCTAssertGreaterThan(result.contactCount, 0)
    }

    func testPairCorrectionsConservePositionDeltaWithinOnePercent() throws {
        let first = rectangle(0, 0, 2, 2)
        let second = rectangle(1, 0, 3, 2)
        let initial = makeSnapshot(first: first, second: second).particles

        let result = try runFrame(first: first, second: second)
        let totalDelta = zip(initial, result.particles).reduce(SIMD2<Float>.zero) { sum, pair in
            sum + pair.1.position - pair.0.position
        }
        let totalMovement = zip(initial, result.particles).reduce(Float.zero) { sum, pair in
            sum + simd_length(pair.1.position - pair.0.position)
        }

        XCTAssertLessThanOrEqual(simd_length(totalDelta), max(0.000_1, totalMovement * 0.01))
    }

    func testNearDegenerateEdgeRemainsFinite() throws {
        let first = [Vector2(x: 0.5, y: 0.5), Vector2(x: 0.75, y: 0.5), Vector2(x: 0.5, y: 0.75)]
        let second = [Vector2(x: 0, y: 0), Vector2(x: 1e-7, y: 0), Vector2(x: 2, y: 0), Vector2(x: 2, y: 2), Vector2(x: 0, y: 2)]

        let result = try runFrame(first: first, second: second)

        XCTAssertTrue(result.particles.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    private func runFrame(first: [Vector2], second: [Vector2]) throws -> (particles: [MetalParticle], contactCount: Int) {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let snapshot = makeSnapshot(first: first, second: second)
        let session = try MetalSimulationSession(snapshot: snapshot, device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let command = try XCTUnwrap(queue.makeCommandBuffer())
        let resources = try session.encodeFrame(input: .init(gravity: .zero), commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        let pointer = resources.particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: resources.particleCount)
        return (Array(UnsafeBufferPointer(start: pointer, count: resources.particleCount)), Int(resources.contourContactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee))
    }

    private func makeSnapshot(first: [Vector2], second: [Vector2]) -> MetalWorldSnapshot {
        var particles: [MetalParticle] = []
        var ranges: [MetalBubbleRange] = []
        for (bubbleIndex, contour) in [first, second].enumerated() {
            let center = contour.reduce(SIMD2<Float>.zero) { $0 + SIMD2($1.x, $1.y) } / Float(contour.count)
            let centerIndex = particles.count
            particles.append(.init(position: center, previousPosition: center, inverseMass: 1, bubbleIndex: UInt32(bubbleIndex)))
            let start = particles.count
            particles.append(contentsOf: contour.map { point in
                .init(position: SIMD2(point.x, point.y), previousPosition: SIMD2(point.x, point.y), inverseMass: 1, bubbleIndex: UInt32(bubbleIndex))
            })
            ranges.append(.init(id: UInt32(bubbleIndex + 1), centerIndex: UInt32(centerIndex), boundaryStart: UInt32(start), boundaryCount: UInt32(contour.count), restArea: 1))
        }
        let configuration = WorldConfiguration(fixedTimeStep: 1 / 60, solverIterations: 1, maxBoundarySegmentLength: 8, linearDamping: 0)
        return MetalWorldSnapshot(particles: particles, bubbleRanges: ranges, configuration: configuration)
    }

    private func rectangle(_ minX: Float, _ minY: Float, _ maxX: Float, _ maxY: Float) -> [Vector2] {
        [Vector2(x: minX, y: minY), Vector2(x: maxX, y: minY), Vector2(x: maxX, y: maxY), Vector2(x: minX, y: maxY)]
    }
}
