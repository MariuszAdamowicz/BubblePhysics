import Metal
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalUnifiedContactTests: XCTestCase {
    func testSelfIntersectingContourIsSeparatedWithoutTouchingAdjacentSegments() throws {
        let contour = [
            SIMD2<Float>(20, 20), SIMD2<Float>(80, 80),
            SIMD2<Float>(20, 80), SIMD2<Float>(80, 20)
        ]
        let snapshot = singleBubbleSnapshot(contour: contour, solverIterations: 12)

        let particles = try runPersistentFrame(snapshot: snapshot, input: .init(gravity: .zero))
        let range = snapshot.bubbleRanges[0]
        let output = (0..<Int(range.boundaryCount)).map { particles[Int(range.boundaryStart) + $0].position }

        XCTAssertFalse(segmentsProperlyIntersect(output[0], output[1], output[2], output[3]))
        XCTAssertTrue(output.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }

    func testRepeatedCornerCompressionStaysFiniteAndInsideBounds() throws {
        let contour = [SIMD2<Float>(-40, -40), SIMD2<Float>(80, -40), SIMD2<Float>(80, 80), SIMD2<Float>(-40, 80)]
        let bounds = AABB(minimum: .zero, maximum: Vector2(x: 30, y: 30))
        var snapshot = singleBubbleSnapshot(contour: contour, solverIterations: 8)

        for _ in 0..<4 {
            let particles = try runPersistentFrame(snapshot: snapshot, input: .init(gravity: .zero, bounds: bounds))
            snapshot = snapshot.replacingParticles(particles)
        }

        XCTAssertTrue(snapshot.particles.allSatisfy {
            $0.position.x.isFinite && $0.position.y.isFinite &&
                $0.position.x >= 0 && $0.position.x <= 30 && $0.position.y >= 0 && $0.position.y <= 30
        })
    }

    func testPolygonSurfaceVelocitySupportsStaticLinearAndAngularMotion() async throws {
        let stationary = try await contactVelocities(linear: .zero, angular: 0)
        let translating = try await contactVelocities(linear: Vector2(x: 12, y: 0), angular: 0)
        let rotating = try await contactVelocities(linear: .zero, angular: 2)

        XCTAssertTrue(stationary.allSatisfy { abs($0.x) < 0.000_01 && abs($0.y) < 0.000_01 })
        XCTAssertTrue(translating.contains { $0.x > 0.01 })
        XCTAssertTrue(rotating.contains { abs($0.y) > 0.001 })
    }

    private func contactVelocities(linear: Vector2, angular: Float) async throws -> [SIMD2<Float>] {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 58, y: 50), restArea: .pi * 25)
        var polygon = try RigidPolygon.make(
            id: PolygonID(rawValue: 1),
            vertices: [Vector2(x: -5, y: -12), Vector2(x: 5, y: -12), Vector2(x: 5, y: 12), Vector2(x: -5, y: 12)],
            mode: .kinematic
        )
        polygon.setKinematicTransform(position: Vector2(x: 50, y: 50), angleRadians: 0, linearVelocity: linear, angularVelocity: angular)
        world.addRigidPolygon(polygon)
        let result = try await solver.solveInteractions(snapshot: MetalWorldSnapshot(world: world), configuration: .default)
        return result.particles.map { $0.position - $0.previousPosition }
    }

    private func runPersistentFrame(snapshot: MetalWorldSnapshot, input: MetalFrameInput) throws -> [MetalParticle] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let session = try MetalSimulationSession(snapshot: snapshot, device: device)
        let command = try XCTUnwrap(device.makeCommandQueue()?.makeCommandBuffer())
        let resources = try session.encodeFrame(input: input, commandBuffer: command)
        command.commit(); command.waitUntilCompleted()
        let pointer = resources.particleBuffer.contents().bindMemory(to: MetalParticle.self, capacity: resources.particleCount)
        return Array(UnsafeBufferPointer(start: pointer, count: resources.particleCount))
    }

    private func singleBubbleSnapshot(contour: [SIMD2<Float>], solverIterations: Int) -> MetalWorldSnapshot {
        let center = contour.reduce(.zero, +) / Float(contour.count)
        var particles = [MetalParticle(position: center, previousPosition: center, inverseMass: 1, bubbleIndex: 0)]
        particles.append(contentsOf: contour.map { MetalParticle(position: $0, previousPosition: $0, inverseMass: 1, bubbleIndex: 0) })
        let range = MetalBubbleRange(id: 1, centerIndex: 0, boundaryStart: 1, boundaryCount: UInt32(contour.count), restArea: 1)
        let configuration = WorldConfiguration(fixedTimeStep: 1 / 60, solverIterations: solverIterations, maxBoundarySegmentLength: 8, linearDamping: 0)
        return MetalWorldSnapshot(particles: particles, bubbleRanges: [range], configuration: configuration)
    }

    private func segmentsProperlyIntersect(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool {
        func cross(_ x: SIMD2<Float>, _ y: SIMD2<Float>) -> Float { x.x * y.y - x.y * y.x }
        let denominator = cross(b - a, d - c)
        guard abs(denominator) > 1e-6 else { return false }
        let t = cross(c - a, d - c) / denominator
        let u = cross(c - a, b - a) / denominator
        return t > 0 && t < 1 && u > 0 && u < 1
    }
}
