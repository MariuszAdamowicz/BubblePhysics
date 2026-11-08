import BubblePhysicsModel

// ABI Swift/MSL: wyłącznie lane'y SIMD o wyrównaniu 16 bajtów.
struct NativeMetalBubble: Equatable, Sendable {
    var identity: SIMD2<Int64>
    var position: SIMD4<Float> // center.xy, previousCenter.xy
    var motion: SIMD4<Float> // velocity.xy, rotation, angularVelocity
    var physical: SIMD4<Float> // mass, inverseMass, radius, stiffness
    var deformation: SIMD4<Float> // maksymalna względna deformacja konturu, reserved
    var publicFlags = SIMD4<UInt32>.zero
    var material = SIMD4<Float>.zero
    var resources = SIMD2<UInt64>.zero
    var eventData = SIMD2<UInt64>.zero // interest, merge groups

    init(_ bubble: NativeSolverBubble) {
        identity = SIMD2(Int64(bubble.id.rawValue), 0)
        position = SIMD4(bubble.center.x, bubble.center.y, bubble.previousCenter.x, bubble.previousCenter.y)
        motion = SIMD4(bubble.velocity.x, bubble.velocity.y, bubble.rotation, bubble.angularVelocity)
        physical = SIMD4(bubble.mass, bubble.inverseMass, bubble.targetRadius, bubble.stiffness)
        deformation = .zero
    }

    func unpack(into bubble: inout NativeSolverBubble) {
        bubble.center = SIMD2(position.x, position.y)
        bubble.previousCenter = SIMD2(position.z, position.w)
        bubble.velocity = SIMD2(motion.x, motion.y)
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

    init(_ segment: NativeSolverSegment) {
        identity = SIMD2(Int64(segment.id), Int64(segment.ownerID ?? 0))
        flags = SIMD4(segment.isKinematic ? 1 : 0, segment.ownerID == nil ? 0 : 1,
                      segment.allowedSide == nil ? 0 : 1, 0)
        previous = SIMD4(segment.previousA.x, segment.previousA.y, segment.previousB.x, segment.previousB.y)
        current = SIMD4(segment.currentA.x, segment.currentA.y, segment.currentB.x, segment.currentB.y)
        velocity = SIMD4(segment.linearVelocity.x, segment.linearVelocity.y, segment.angularVelocity, 0)
        collision = SIMD4(segment.allowedSide ?? 0, 0, 0, 0)
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

struct NativeMetalEventRecord: Sendable {
    var participants: SIMD2<UInt64>
    var point: SIMD4<Float>
    var metadata: SIMD4<UInt32> // 0 merge, 1 enter, 2 exit
}

struct NativeMetalSensorRecord: Sendable {
    var identity: SIMD2<UInt64> // sensor ID, EventInterest
    var geometry: SIMD4<Float> // center.xy, rotation, circle radius (0 = polygon)
    var range: SIMD4<UInt32> // vertex offset/count
}

struct NativeMetalSensorPair: Sendable {
    var participants: SIMD2<UInt64> // sensor, bubble
    var state: SIMD4<UInt32> // overlapping, reserved
}

struct NativeMetalGridEntry: Sendable {
    var cell: SIMD2<Int64>
    var metadata: SIMD4<UInt32> // bubbleIndex, valid, reserved
}

struct NativeMetalContactControl: Sendable {
    var limits: SIMD4<UInt32> // frame, expiry, capacity, previousCacheCount
    var counts: SIMD4<UInt32> // candidates, contacts, cache, failure
    var cache: SIMD4<UInt32> // hits, resets, invalidationCount, rowStride
    var thresholds: SIMD4<Float> // teleportMultiplier, ccdMultiplier, contactTolerance, separationTolerance
    var cellWidth: SIMD4<Float>
}

struct NativeMetalControl: Sendable {
    var counts: SIMD4<UInt32> // bubbles, segments, scenarioStep, failure
    var physics: SIMD4<Float> // dt, linearDamping, angularDamping, contactStiffness
    var contactDamping: SIMD4<Float>
    var region = SIMD4<Float>.zero
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

struct NativeMetalContourControl: Sendable {
    var counts: SIMD4<UInt32> // stride punktów, poprzednia liczba baniek, reserved
    var shape: SIMD4<Float> // maksymalna krawędź, recovery rate, napięcie, clearance
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

struct NativeMetalSegmentRemap: Sendable {
    let sourceIndex: Int
    let destinationIndex: Int
}

/// Pełne modele służą identyfikacji i readbackowi; pakowane są tylko zmiany CPU.
/// Poprzedni snapshot musi należeć do ostatniej pomyślnie wykonanej klatki.
struct NativeMetalSnapshot: Sendable {
    let configuration: NativeSolverConfiguration
    var sourceBubbles: [NativeSolverBubble]
    let sourceSegments: [NativeSolverSegment]
    let bubbleChanges: [NativeMetalBubbleChange]
    let bubbleRemaps: [NativeMetalBubbleRemap]
    let segmentChanges: [NativeMetalSegmentChange]
    let segmentRemaps: [NativeMetalSegmentRemap]
    let previousBubbles: [NativeSolverBubble]?
    let previousSegments: [NativeSolverSegment]?
    let publicSettings: NativePublicSettings?

    init(input: NativeSolverInput, previous: NativeMetalSnapshot? = nil) {
        let publicSettings = input.publicSettings
        self.publicSettings = publicSettings
        configuration = input.configuration
        sourceBubbles = input.bubbles
        sourceSegments = input.segments
        previousBubbles = previous?.sourceBubbles
        previousSegments = previous?.sourceSegments
        let previousByID = Dictionary(uniqueKeysWithValues: (previous?.sourceBubbles ?? []).enumerated().map {
            ($0.element.id, (index: $0.offset, bubble: $0.element))
        })
        bubbleChanges = input.bubbles.enumerated().compactMap { index, bubble in
            let properties = publicSettings?.properties[bubble.id]
            guard previousByID[bubble.id]?.bubble != bubble || properties != previous?.publicSettings?.properties[bubble.id] else { return nil }
            var value = NativeMetalBubble(bubble)
            if let properties {
                value.publicFlags = properties.flags; value.material = properties.material; value.resources = properties.resources
                // GPU nie rozwiązuje po ID zasobu; wolny lane niesie stabilną
                // restitucję bez współdzielenia bufora deformacji konturu.
                value.resources.x = UInt64(properties.restitution.bitPattern)
                value.eventData = properties.eventData
            }
            return .init(index: index, value: value)
        }
        bubbleRemaps = input.bubbles.enumerated().compactMap { index, bubble in
            guard let existing = previousByID[bubble.id], existing.bubble == bubble,
                  existing.index != index else { return nil }
            return .init(sourceIndex: existing.index, destinationIndex: index)
        }
        let previousSegmentsByID = Dictionary(uniqueKeysWithValues: (previous?.sourceSegments ?? []).enumerated().map {
            ($0.element.id, (index: $0.offset, segment: $0.element))
        })
        func segmentMaterial(_ segment: NativeSolverSegment, _ settings: NativePublicSettings?) -> PhysicsMaterial? {
            guard let owner = segment.ownerID else { return nil }
            return settings?.staticPolygonMaterials[ObjectID(rawValue: UInt64(bitPattern: Int64(owner)))]
        }
        segmentChanges = input.segments.enumerated().compactMap { index, segment in
            guard previousSegmentsByID[segment.id]?.segment != segment
                    || segmentMaterial(segment, publicSettings) != segmentMaterial(segment, previous?.publicSettings)
            else { return nil }
            var value = NativeMetalSegment(segment)
            if let material = segmentMaterial(segment, publicSettings) {
                value.collision.y = material.friction
                value.collision.z = material.restitution
            }
            return .init(index: index, value: value)
        }
        segmentRemaps = input.segments.enumerated().compactMap { index, segment in
            guard let previous = previousSegmentsByID[segment.id], previous.segment == segment,
                  previous.index != index else { return nil }
            return .init(sourceIndex: previous.index, destinationIndex: index)
        }
    }
}

public struct NativeMetalFrameProfile: Equatable, Sendable {
    public var commandBufferCount = 0
    public var encoderCount = 0
    /// Rekordy wejściowe zmienione przez grę; własna publikacja GPU nie jest uploadem.
    public var bubbleUploadCount = 0
    public var segmentUploadCount = 0
    /// Polecenia blit, które przeniosły `bubbleUploadCount` rekordów po scaleniu ciągłych indeksów.
    public var bubbleUploadCommandCount = 0
    public var rigidBodyUploadCount = 0
    public var rigidGeometryUploadCount = 0
    public var hostEncodingMilliseconds: Double = 0
    public var hostWaitingMilliseconds: Double = 0
    /// Łączny czas ukończonego command buffera; bez pozornych czasów osobnych dispatchy.
    public var stageGPUMilliseconds: [String: Double] = [:]
    /// Opcjonalne liczniki rzeczywiście wykonanych work-itemów, używane w profilu przepustowości.
    public var stageGPUWorkItemCounts: [String: Int] = [:]

    public init() {}
}
