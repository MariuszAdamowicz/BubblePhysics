import BubblePhysics
import simd

public struct MetalWorldSnapshot: Equatable, Sendable {
    public let particles: [MetalParticle]
    public let bubbleRanges: [MetalBubbleRange]
    public let distanceConstraints: [MetalDistanceConstraint]
    public let springConstraints: [MetalSpringConstraint]
    public let areaConstraints: [MetalAreaConstraint]
    public let polygons: [SimulationPolygonSnapshot]
    public let grabs: [SimulationGrabSnapshot]
    public let configuration: WorldConfiguration

    public init(
        particles: [MetalParticle], bubbleRanges: [MetalBubbleRange],
        distanceConstraints: [MetalDistanceConstraint] = [], springConstraints: [MetalSpringConstraint] = [], areaConstraints: [MetalAreaConstraint] = [],
        polygons: [SimulationPolygonSnapshot] = [], grabs: [SimulationGrabSnapshot] = [],
        configuration: WorldConfiguration = .default
    ) {
        self.particles = particles
        self.bubbleRanges = bubbleRanges
        self.distanceConstraints = distanceConstraints
        self.springConstraints = springConstraints
        self.areaConstraints = areaConstraints
        self.polygons = polygons
        self.grabs = grabs
        self.configuration = configuration
    }

    public init(world: BubbleWorld) {
        self.init(snapshot: world.simulationSnapshot())
    }

    public init(snapshot: SimulationWorldSnapshot) {
        var bubbleIndices = Array(repeating: UInt32.max, count: snapshot.particles.count)
        var ranges: [MetalBubbleRange] = []
        var encodedSpringConstraints: [MetalSpringConstraint] = []
        ranges.reserveCapacity(snapshot.bubbles.count)
        var springConstraintCursor = 0

        for (bubbleIndex, bubble) in snapshot.bubbles.enumerated() {
            let encodedBubbleIndex = UInt32(bubbleIndex)
            bubbleIndices[bubble.centerIndex] = encodedBubbleIndex
            for index in bubble.boundaryIndices {
                bubbleIndices[index] = encodedBubbleIndex
            }
            let constraintCount = bubble.boundaryIndices.count * 3
            let constraints = snapshot.springConstraints[
                springConstraintCursor..<min(springConstraintCursor + constraintCount, snapshot.springConstraints.count)
            ]
            let constraintStart = encodedSpringConstraints.count
            encodedSpringConstraints.append(contentsOf: constraints.compactMap {
                guard let kind = MetalSpringKind(rawValue: $0.kindRawValue) else { return nil }
                return MetalSpringConstraint(
                    firstIndex: UInt32($0.firstIndex),
                    secondIndex: UInt32($0.secondIndex),
                    restLength: $0.restLength,
                    kind: kind
                )
            })
            springConstraintCursor += constraints.count
            ranges.append(MetalBubbleRange(
                id: UInt32(bubble.id.rawValue),
                centerIndex: UInt32(bubble.centerIndex),
                boundaryStart: UInt32(bubble.boundaryIndices.first ?? 0),
                boundaryCount: UInt32(bubble.boundaryIndices.count),
                restArea: bubble.restArea,
                distanceConstraintStart: UInt32(constraintStart),
                distanceConstraintCount: UInt32(constraints.count)
            ))
        }

        particles = snapshot.particles.enumerated().map { index, particle in
            MetalParticle(
                position: SIMD2<Float>(particle.position.x, particle.position.y),
                previousPosition: SIMD2<Float>(particle.previousPosition.x, particle.previousPosition.y),
                inverseMass: particle.inverseMass,
                bubbleIndex: bubbleIndices[index]
            )
        }
        bubbleRanges = ranges
        distanceConstraints = []
        springConstraints = encodedSpringConstraints
        areaConstraints = []
        polygons = snapshot.polygons
        grabs = snapshot.grabs
        configuration = snapshot.configuration
    }

    public func encodedBuffers() -> MetalEncodedWorldBuffers {
        MetalEncodedWorldBuffers(
            particles: particles,
            bubbleRanges: bubbleRanges,
            distanceConstraints: distanceConstraints,
            springConstraints: springConstraints,
            areaConstraints: areaConstraints
        )
    }

    public func replacingParticles(_ particles: [MetalParticle]) -> MetalWorldSnapshot {
        MetalWorldSnapshot(particles: particles, bubbleRanges: bubbleRanges, distanceConstraints: distanceConstraints, springConstraints: springConstraints, areaConstraints: areaConstraints, polygons: polygons, grabs: grabs, configuration: configuration)
    }
}
