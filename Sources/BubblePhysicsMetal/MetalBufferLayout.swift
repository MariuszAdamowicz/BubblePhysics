import simd

public struct MetalParticle: Equatable, Sendable {
    public var position: SIMD2<Float>
    public var previousPosition: SIMD2<Float>
    public var inverseMass: Float
    public var bubbleIndex: UInt32
    public var padding: SIMD2<Float> = .zero

    public init(position: SIMD2<Float>, previousPosition: SIMD2<Float>, inverseMass: Float, bubbleIndex: UInt32) {
        self.position = position
        self.previousPosition = previousPosition
        self.inverseMass = inverseMass
        self.bubbleIndex = bubbleIndex
    }
}

public struct MetalBubbleRange: Equatable, Sendable {
    public var id: UInt32
    public var centerIndex: UInt32
    public var boundaryStart: UInt32
    public var boundaryCount: UInt32
    public var restArea: Float
    public var distanceConstraintStart: UInt32
    public var distanceConstraintCount: UInt32
    public var padding: Float = 0

    public init(
        id: UInt32,
        centerIndex: UInt32,
        boundaryStart: UInt32,
        boundaryCount: UInt32,
        restArea: Float,
        distanceConstraintStart: UInt32 = 0,
        distanceConstraintCount: UInt32 = 0
    ) {
        self.id = id
        self.centerIndex = centerIndex
        self.boundaryStart = boundaryStart
        self.boundaryCount = boundaryCount
        self.restArea = restArea
        self.distanceConstraintStart = distanceConstraintStart
        self.distanceConstraintCount = distanceConstraintCount
    }
}

public struct MetalDistanceConstraint: Equatable, Sendable {
    public var firstIndex: UInt32
    public var secondIndex: UInt32
    public var restLength: Float
    public var compliance: Float

    public init(firstIndex: UInt32, secondIndex: UInt32, restLength: Float, compliance: Float) {
        self.firstIndex = firstIndex
        self.secondIndex = secondIndex
        self.restLength = restLength
        self.compliance = compliance
    }
}

public enum MetalSpringKind: UInt32, CaseIterable, Sendable {
    case radial
    case perimeter
    case bending
}

public struct MetalSpringConstraint: Equatable, Sendable {
    public var firstIndex: UInt32
    public var secondIndex: UInt32
    public var restLength: Float
    public var kindRawValue: UInt32
    public var padding: SIMD2<Float> = .zero

    public var kind: MetalSpringKind {
        get { MetalSpringKind(rawValue: kindRawValue) ?? .radial }
        set { kindRawValue = newValue.rawValue }
    }

    public init(firstIndex: UInt32, secondIndex: UInt32, restLength: Float, kind: MetalSpringKind) {
        self.firstIndex = firstIndex
        self.secondIndex = secondIndex
        self.restLength = restLength
        kindRawValue = kind.rawValue
    }
}

public struct MetalAreaConstraint: Equatable, Sendable {
    public var boundaryStart: UInt32
    public var boundaryCount: UInt32
    public var restArea: Float
    public var compliance: Float

    public init(boundaryStart: UInt32, boundaryCount: UInt32, restArea: Float, compliance: Float) {
        self.boundaryStart = boundaryStart
        self.boundaryCount = boundaryCount
        self.restArea = restArea
        self.compliance = compliance
    }
}

public struct MetalPolygonRange: Equatable, Sendable {
    public var vertexStart: UInt32
    public var vertexCount: UInt32
    public var triangleStart: UInt32
    public var triangleCount: UInt32
}

public struct MetalInteractionPolygon: Equatable, Sendable {
    public var vertexStart: UInt32
    public var vertexCount: UInt32
    public var position: SIMD2<Float>
    public var linearVelocity: SIMD2<Float>
    public var angularVelocity: Float
    public var padding: Float = 0
}

public struct MetalGrab: Equatable, Sendable {
    public var particleIndex: UInt32
    public var padding: UInt32 = 0
    public var target: SIMD2<Float>
    public var maximumCorrection: Float
    public var trailingPadding: SIMD3<Float> = .zero
}

public struct MetalBubblePair: Equatable, Sendable, Comparable {
    public let firstID: UInt32
    public let secondID: UInt32

    public init(firstID: UInt32, secondID: UInt32) {
        self.firstID = min(firstID, secondID)
        self.secondID = max(firstID, secondID)
    }

    public static func < (lhs: MetalBubblePair, rhs: MetalBubblePair) -> Bool {
        lhs.firstID == rhs.firstID ? lhs.secondID < rhs.secondID : lhs.firstID < rhs.firstID
    }
}

public struct MetalCorrection: Equatable, Sendable {
    public let particleIndex: UInt32
    public let sourceIndex: UInt32
    public let delta: SIMD2<Float>

    public init(particleIndex: UInt32, sourceIndex: UInt32 = 0, delta: SIMD2<Float>) {
        self.particleIndex = particleIndex
        self.sourceIndex = sourceIndex
        self.delta = delta
    }
}

public struct MetalEncodedWorldBuffers: Equatable, Sendable {
    public let particles: [MetalParticle]
    public let bubbleRanges: [MetalBubbleRange]
    public let distanceConstraints: [MetalDistanceConstraint]
    public let springConstraints: [MetalSpringConstraint]
    public let areaConstraints: [MetalAreaConstraint]

    public init(
        particles: [MetalParticle],
        bubbleRanges: [MetalBubbleRange],
        distanceConstraints: [MetalDistanceConstraint] = [],
        springConstraints: [MetalSpringConstraint] = [],
        areaConstraints: [MetalAreaConstraint] = []
    ) {
        self.particles = particles
        self.bubbleRanges = bubbleRanges
        self.distanceConstraints = distanceConstraints
        self.springConstraints = springConstraints
        self.areaConstraints = areaConstraints
    }
}
