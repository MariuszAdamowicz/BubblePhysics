import Metal
import simd
import XCTest
@testable import BubblePhysics
@testable import BubblePhysicsMetal

final class MetalSpringSolverTests: XCTestCase {
    func testSnapshotEncodesThreeSpringFamiliesAndNoActiveAreaConstraint() {
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 100)
        let snapshot = MetalWorldSnapshot(world: world)

        XCTAssertEqual(Set(snapshot.springConstraints.map(\.kind)), Set(MetalSpringKind.allCases))
        XCTAssertEqual(snapshot.springConstraints.count, Int(snapshot.bubbleRanges[0].boundaryCount) * 3)
        XCTAssertTrue(snapshot.areaConstraints.isEmpty)
    }

    func testCompressedContourExpandsFromSpringsWithoutAreaProjection() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        let material = SpringMaterial(quadraticStiffness: 1_200, quarticStiffness: 12, drag: 0)
        let configuration = WorldConfiguration(
            fixedTimeStep: 1 / 60,
            solverIterations: 8,
            maxBoundarySegmentLength: 8,
            linearDamping: 0,
            springMaterial: material
        )
        var world = BubbleWorld(configuration: configuration)
        world.addBubble(center: Vector2(x: 50, y: 50), restArea: .pi * 100)
        let original = MetalWorldSnapshot(world: world)
        let center = original.particles[Int(original.bubbleRanges[0].centerIndex)].position
        let compressedParticles = original.particles.enumerated().map { index, particle -> MetalParticle in
            guard index != Int(original.bubbleRanges[0].centerIndex) else { return particle }
            var copy = particle
            copy.position = center + (particle.position - center) * 0.2
            copy.previousPosition = copy.position
            return copy
        }
        let compressed = original.replacingParticles(compressedParticles)
        let before = averageRadius(compressed)

        let result = try await solver.solveShape(snapshot: compressed, gravity: .zero, bounds: nil, configuration: configuration)

        XCTAssertGreaterThan(averageRadius(result.particles, range: compressed.bubbleRanges[0]), before)
        XCTAssertTrue(result.particles.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    func testCoincidentSpringEndpointsStayFinite() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        var world = BubbleWorld(configuration: .default)
        world.addBubble(center: Vector2(x: 20, y: 20), restArea: .pi * 25)
        let original = MetalWorldSnapshot(world: world)
        let point = original.particles[0].position
        let collapsed = original.replacingParticles(original.particles.map {
            MetalParticle(position: point, previousPosition: point, inverseMass: $0.inverseMass, bubbleIndex: $0.bubbleIndex)
        })

        let result = try await solver.solveShape(snapshot: collapsed, gravity: .zero, bounds: nil, configuration: .default)

        XCTAssertTrue(result.particles.allSatisfy { $0.position.x.isFinite && $0.position.y.isFinite })
    }

    func testPerSpringStiffnessScaleChangesGPUCorrection() async throws {
        guard let solver = MetalBubbleSolver() else { throw XCTSkip("Metal unavailable") }
        let particles = [
            MetalParticle(position: SIMD2(0, 0), previousPosition: SIMD2(0, 0), inverseMass: 1, bubbleIndex: 0),
            MetalParticle(position: SIMD2(10, 0), previousPosition: SIMD2(10, 0), inverseMass: 1, bubbleIndex: 0),
        ]
        let range = MetalBubbleRange(id: 1, centerIndex: 0, boundaryStart: 1, boundaryCount: 1, restArea: 1, distanceConstraintStart: 0, distanceConstraintCount: 1)
        let configuration = WorldConfiguration(fixedTimeStep: 1 / 60, solverIterations: 1, maxBoundarySegmentLength: 8, linearDamping: 0, springMaterial: .init(quadraticStiffness: 100, quarticStiffness: 0, drag: 0))
        func snapshot(scale: Float) -> MetalWorldSnapshot {
            MetalWorldSnapshot(
                particles: particles,
                bubbleRanges: [range],
                springConstraints: [.init(firstIndex: 0, secondIndex: 1, restLength: 5, kind: .perimeter, stiffnessScale: scale)],
                configuration: configuration
            )
        }

        let normal = try await solver.solveShape(snapshot: snapshot(scale: 1), gravity: .zero, bounds: nil, configuration: configuration)
        let doubled = try await solver.solveShape(snapshot: snapshot(scale: 2), gravity: .zero, bounds: nil, configuration: configuration)

        XCTAssertLessThan(doubled.particles[1].position.x - doubled.particles[0].position.x, normal.particles[1].position.x - normal.particles[0].position.x)
    }

    private func averageRadius(_ snapshot: MetalWorldSnapshot) -> Float {
        averageRadius(snapshot.particles, range: snapshot.bubbleRanges[0])
    }

    private func averageRadius(_ particles: [MetalParticle], range: MetalBubbleRange) -> Float {
        let center = particles[Int(range.centerIndex)].position
        let radii = (0..<Int(range.boundaryCount)).map { index -> Float in
            simd_length(particles[Int(range.boundaryStart) + index].position - center)
        }
        return radii.reduce(0, +) / Float(radii.count)
    }
}
