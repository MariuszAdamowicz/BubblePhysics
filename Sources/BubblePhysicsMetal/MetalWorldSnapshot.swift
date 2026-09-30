import BubblePhysics
import simd

public struct MetalWorldSnapshot: Equatable, Sendable {
    public let particles: [MetalParticle]
    public let bubbleRanges: [MetalBubbleRange]
    public let distanceConstraints: [MetalDistanceConstraint]
    public let areaConstraints: [MetalAreaConstraint]
    public let polygons: [SimulationPolygonSnapshot]
    public let grabs: [SimulationGrabSnapshot]
    public let configuration: WorldConfiguration

    public init(
        particles: [MetalParticle], bubbleRanges: [MetalBubbleRange],
        distanceConstraints: [MetalDistanceConstraint], areaConstraints: [MetalAreaConstraint],
        polygons: [SimulationPolygonSnapshot] = [], grabs: [SimulationGrabSnapshot] = [],
        configuration: WorldConfiguration = .default
    ) {
        self.particles = particles
        self.bubbleRanges = bubbleRanges
        self.distanceConstraints = distanceConstraints
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
        var encodedDistanceConstraints: [MetalDistanceConstraint] = []
        var encodedAreaConstraints: [MetalAreaConstraint] = []
        ranges.reserveCapacity(snapshot.bubbles.count)
        encodedAreaConstraints.reserveCapacity(snapshot.bubbles.count)
        var distanceConstraintCursor = 0

        for (bubbleIndex, bubble) in snapshot.bubbles.enumerated() {
            let encodedBubbleIndex = UInt32(bubbleIndex)
            bubbleIndices[bubble.centerIndex] = encodedBubbleIndex
            for index in bubble.boundaryIndices {
                bubbleIndices[index] = encodedBubbleIndex
            }
            let constraintCount = bubble.boundaryIndices.count * 3
            let constraints = snapshot.distanceConstraints[
                distanceConstraintCursor..<min(distanceConstraintCursor + constraintCount, snapshot.distanceConstraints.count)
            ]
            let constraintStart = encodedDistanceConstraints.count
            encodedDistanceConstraints.append(contentsOf: constraints.map {
                MetalDistanceConstraint(
                    firstIndex: UInt32($0.firstIndex),
                    secondIndex: UInt32($0.secondIndex),
                    restLength: $0.restLength,
                    compliance: $0.compliance
                )
            })
            distanceConstraintCursor += constraints.count
            ranges.append(MetalBubbleRange(
                id: UInt32(bubble.id.rawValue),
                centerIndex: UInt32(bubble.centerIndex),
                boundaryStart: UInt32(bubble.boundaryIndices.first ?? 0),
                boundaryCount: UInt32(bubble.boundaryIndices.count),
                restArea: bubble.restArea,
                distanceConstraintStart: UInt32(constraintStart),
                distanceConstraintCount: UInt32(constraints.count)
            ))
            let area = snapshot.areaConstraints.indices.contains(bubbleIndex)
                ? snapshot.areaConstraints[bubbleIndex]
                : SimulationAreaConstraintSnapshot(
                    boundaryIndices: bubble.boundaryIndices,
                    restArea: bubble.restArea,
                    compliance: 0
                )
            encodedAreaConstraints.append(MetalAreaConstraint(
                boundaryStart: UInt32(area.boundaryIndices.first ?? 0),
                boundaryCount: UInt32(area.boundaryIndices.count),
                restArea: area.restArea,
                compliance: area.compliance
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
        distanceConstraints = encodedDistanceConstraints
        areaConstraints = encodedAreaConstraints
        polygons = snapshot.polygons
        grabs = snapshot.grabs
        configuration = snapshot.configuration
    }

    public func encodedBuffers() -> MetalEncodedWorldBuffers {
        MetalEncodedWorldBuffers(
            particles: particles,
            bubbleRanges: bubbleRanges,
            distanceConstraints: distanceConstraints,
            areaConstraints: areaConstraints
        )
    }

    public func replacingParticles(_ particles: [MetalParticle]) -> MetalWorldSnapshot {
        MetalWorldSnapshot(particles: particles, bubbleRanges: bubbleRanges, distanceConstraints: distanceConstraints, areaConstraints: areaConstraints, polygons: polygons, grabs: grabs, configuration: configuration)
    }
}
