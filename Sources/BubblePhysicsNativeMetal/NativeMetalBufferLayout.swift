import BubblePhysicsReference

// ABI Swift/MSL: wyłącznie lane'y SIMD o wyrównaniu 16 bajtów.
struct NativeMetalBubble: Equatable, Sendable {
    var identity: SIMD2<Int64>
    var position: SIMD4<Float> // center.xy, previousCenter.xy
    var motion: SIMD4<Float> // velocity.xy, rotation, angularVelocity
    var physical: SIMD4<Float> // mass, inverseMass, radius, stiffness
    var deformation: SIMD4<Float> // zarezerwowane dla solvera kontaktów

    init(_ bubble: ReferenceBubble) {
        identity = SIMD2(Int64(bubble.id.rawValue), 0)
        position = SIMD4(bubble.center.x, bubble.center.y, bubble.previousCenter.x, bubble.previousCenter.y)
        motion = SIMD4(bubble.velocity.x, bubble.velocity.y, bubble.rotation, bubble.angularVelocity)
        physical = SIMD4(bubble.mass, bubble.inverseMass, bubble.targetRadius, bubble.stiffness)
        deformation = .zero
    }

    func unpack(into bubble: inout ReferenceBubble) {
        bubble.center = .init(x: position.x, y: position.y)
        bubble.previousCenter = .init(x: position.z, y: position.w)
        bubble.velocity = .init(x: motion.x, y: motion.y)
        bubble.rotation = motion.z
        bubble.angularVelocity = motion.w
    }
}

struct NativeMetalSegment: Equatable, Sendable {
    var identity: SIMD2<Int64>
    var flags: SIMD4<UInt32>
    var previous: SIMD4<Float>
    var current: SIMD4<Float>
    var velocity: SIMD4<Float>
    var collision: SIMD4<Float>

    init(_ segment: ReferenceSegment) {
        identity = SIMD2(Int64(segment.id.rawValue), Int64(segment.ownerID ?? 0))
        flags = SIMD4(segment.motion == .kinematic ? 1 : 0, segment.ownerID == nil ? 0 : 1,
                      segment.collisionMode.allowedSide == nil ? 0 : 1, 0)
        previous = SIMD4(segment.previousA.x, segment.previousA.y, segment.previousB.x, segment.previousB.y)
        current = SIMD4(segment.currentA.x, segment.currentA.y, segment.currentB.x, segment.currentB.y)
        velocity = SIMD4(segment.linearVelocity.x, segment.linearVelocity.y, segment.angularVelocity, 0)
        collision = SIMD4(segment.collisionMode.allowedSide ?? 0, 0, 0, 0)
    }
}

/// Klucz bez hashowania/truncacji ID; rodzaj rozdziela przestrzenie identyfikatorów.
struct NativeContactKey: Equatable, Hashable, Comparable, Sendable {
    let kind: UInt32
    let first: Int64
    let second: Int64

    static func bubblePair(_ first: Int64, _ second: Int64) -> Self {
        .init(kind: 0, first: min(first, second), second: max(first, second))
    }

    static func bubbleSegment(_ bubble: Int64, _ segment: Int64) -> Self {
        .init(kind: 1, first: bubble, second: segment)
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
        if lhs.first != rhs.first { return lhs.first < rhs.first }
        return lhs.second < rhs.second
    }
}

struct NativeContactCacheRecord: Equatable, Sendable {
    var participants: SIMD2<Int64> // pełne ID
    var metadata: SIMD4<UInt32> // kind, age, lastSeenFrame, flags
    var geometry: SIMD4<Float> // normal.xy, point.xy
    var response: SIMD4<Float> // lambda, penetration, allowedSide (0 = nil), reserved
    var key: NativeContactKey { .init(kind: metadata.x, first: participants.x, second: participants.y) }
    var lambda: Float { get { response.x } set { response.x = newValue } }
    var age: UInt32 { metadata.y }
    var lastSeenFrame: UInt32 { metadata.z }
    var flags: UInt32 { metadata.w }
}

typealias NativeMetalContactCache = NativeContactCacheRecord

struct NativeMetalCandidate: Sendable {
    var participants: SIMD2<Int64>
    var metadata: SIMD4<UInt32> // kind, bubbleIndex, otherIndex, valid
    var key: NativeContactKey { .init(kind: metadata.x, first: participants.x, second: participants.y) }
}

struct NativeMetalGridEntry: Sendable {
    var cell: SIMD2<Int64>
    var metadata: SIMD4<UInt32> // bubbleIndex, valid, reserved
}

struct NativeMetalContactControl: Sendable {
    var limits: SIMD4<UInt32> // frame, expiry, capacity, previousCacheCount
    var counts: SIMD4<UInt32> // candidates, contacts, cache, failure
    var cache: SIMD4<UInt32> // hits, resets, invalidationCount, rowStride
    var thresholds: SIMD4<Float> // teleportMultiplier, ccdMultiplier, tolerance, cellWidth
}

struct NativeMetalControl: Sendable {
    var counts: SIMD4<UInt32> // bubbles, segments, scenarioStep, failure
    var physics: SIMD4<Float> // dt, linearDamping, angularDamping, reserved
}

struct NativeMetalSolverControl: Sendable {
    var counts: SIMD4<UInt32> // active, iterations, corrections, iteration budget
    var physics: SIMD4<Float> // compliance / dt², position tolerance, final residual, initial residual
}

struct NativeMetalSafetyControl: Sendable {
    var counts: SIMD4<UInt32> // kandydaci CCD, korekcje guardów, resetowane rekordy, bity błędów
}

struct NativeMetalRenderPacket: Equatable, Sendable {
    var identity: SIMD2<Int64>
    var geometry: SIMD4<Float> // center.xy, radius, rotation
    var deformation: SIMD4<Float>
}

struct NativeMetalBubbleChange: Sendable {
    let index: Int
    let value: NativeMetalBubble
}

struct NativeMetalBubbleRemap: Sendable {
    let sourceIndex: Int
    let destinationIndex: Int
}

struct NativeMetalSegmentChange: Sendable {
    let index: Int
    let value: NativeMetalSegment
}

/// Pełne modele służą identyfikacji i readbackowi; pakowane są tylko zmiany CPU.
/// Poprzedni snapshot musi należeć do ostatniej pomyślnie wykonanej klatki.
struct NativeMetalSnapshot: Sendable {
    let configuration: ReferenceConfiguration
    let sourceBubbles: [ReferenceBubble]
    let sourceSegments: [ReferenceSegment]
    let bubbleChanges: [NativeMetalBubbleChange]
    let bubbleRemaps: [NativeMetalBubbleRemap]
    let segmentChanges: [NativeMetalSegmentChange]
    let previousBubbles: [ReferenceBubble]?
    let previousSegments: [ReferenceSegment]?

    init(world: ReferenceWorld, previous: NativeMetalSnapshot? = nil) {
        configuration = world.configuration
        sourceBubbles = world.bubbles
        sourceSegments = world.segments
        previousBubbles = previous?.sourceBubbles
        previousSegments = previous?.sourceSegments
        let previousByID = Dictionary(uniqueKeysWithValues: (previous?.sourceBubbles ?? []).enumerated().map {
            ($0.element.id, (index: $0.offset, bubble: $0.element))
        })
        bubbleChanges = world.bubbles.enumerated().compactMap { index, bubble in
            guard previousByID[bubble.id]?.bubble != bubble else { return nil }
            return .init(index: index, value: .init(bubble))
        }
        bubbleRemaps = world.bubbles.enumerated().compactMap { index, bubble in
            guard let existing = previousByID[bubble.id], existing.bubble == bubble,
                  existing.index != index else { return nil }
            return .init(sourceIndex: existing.index, destinationIndex: index)
        }
        segmentChanges = world.segments.enumerated().compactMap { index, segment in
            guard previous?.sourceSegments.indices.contains(index) != true
                    || previous?.sourceSegments[index] != segment else { return nil }
            return .init(index: index, value: .init(segment))
        }
    }
}

public struct NativeMetalFrameProfile: Equatable, Sendable {
    public var commandBufferCount = 0
    public var encoderCount = 0
    public var hostEncodingMilliseconds: Double = 0
    public var hostWaitingMilliseconds: Double = 0
    /// Łączny czas ukończonego command buffera; bez pozornych czasów osobnych dispatchy.
    public var stageGPUMilliseconds: [String: Double] = [:]
    /// Opcjonalne liczniki rzeczywiście wykonanych work-itemów, używane w profilu przepustowości.
    public var stageGPUWorkItemCounts: [String: Int] = [:]

    public init() {}
}
