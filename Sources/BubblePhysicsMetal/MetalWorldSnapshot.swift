import BubblePhysics
import simd

public struct MetalWorldSnapshot: Equatable, Sendable {
    public let particles: [MetalParticle]
    public let bubbleRanges: [MetalBubbleRange]

    public init(world: BubbleWorld) {
        self.init(snapshot: world.simulationSnapshot())
    }

    public init(snapshot: SimulationWorldSnapshot) {
        var bubbleIndices = Array(repeating: UInt32.max, count: snapshot.particles.count)
        var ranges: [MetalBubbleRange] = []
        ranges.reserveCapacity(snapshot.bubbles.count)

        for (bubbleIndex, bubble) in snapshot.bubbles.enumerated() {
            let encodedBubbleIndex = UInt32(bubbleIndex)
            bubbleIndices[bubble.centerIndex] = encodedBubbleIndex
            for index in bubble.boundaryIndices {
                bubbleIndices[index] = encodedBubbleIndex
            }
            ranges.append(MetalBubbleRange(
                id: UInt32(bubble.id.rawValue),
                centerIndex: UInt32(bubble.centerIndex),
                boundaryStart: UInt32(bubble.boundaryIndices.first ?? 0),
                boundaryCount: UInt32(bubble.boundaryIndices.count),
                restArea: bubble.restArea
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
    }

    public func encodedBuffers() -> MetalEncodedWorldBuffers {
        MetalEncodedWorldBuffers(particles: particles, bubbleRanges: bubbleRanges)
    }
}
