import BubblePhysicsModel

// ABI Swift/MSL: wyłącznie lane'y SIMD o wyrównaniu 16 bajtów.
struct NativeMetalBubble: Equatable, Sendable {
    var identity: SIMD2<Int64>
    var position: SIMD4<Float> // center.xy, previousCenter.xy
    var motion: SIMD4<Float> // velocity.xy, rotation, angularVelocity
    var physical: SIMD4<Float> // mass, inverseMass, radius, stiffness
    var deformation: SIMD4<Float> // maksymalna względna deformacja konturu, promień efektywny, limit prędkości liniowej, kątowej (0 = brak)
    var publicFlags = SIMD4<UInt32>.zero
    var material = SIMD4<Float>.zero
    var resources = SIMD2<UInt64>.zero
    var eventData = SIMD2<UInt64>.zero // interest, merge groups
    var bounds = SIMD4<Float>.zero // AABB zdeformowanego konturu po kroku: min.xy, max.xy
    var filter = NativeMetalFilter.default // kategoria, maska, reserved, warstwa (`NativeMetalFilter.encodeLayer`)

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

/// Filtr kolizji i warstwa w rekordach GPU: kategoria i maska w pierwszych dwóch lane'ach, w trzecim znacznik kinematyczny,
/// w czwartym warstwa. Brak filtra (rekord bez ustawień publicznych) oznacza filtr domyślny i warstwę 0.
enum NativeMetalFilter {
    static let `default` = pack(.default)
    /// Warstwa jako Int32 z odwróconym bitem znaku, więc porządek wartości `uint` zgadza się z porządkiem `Int32`
    /// (kernele porównują warstwy jako `uint`); rozmiar rekordu bez zmian.
    static func encodeLayer(_ layer: Int32) -> UInt32 { UInt32(bitPattern: layer) ^ 0x8000_0000 }
    static func decodeLayer(_ value: UInt32) -> Int32 { Int32(bitPattern: value ^ 0x8000_0000) }
    static func pack(_ filter: CollisionFilter, kinematic: Bool = false, layer: Int32 = 0) -> SIMD4<UInt32> {
        SIMD4(filter.category, filter.mask, kinematic ? 1 : 0, encodeLayer(layer))
    }
}

struct NativeMetalSegment: Equatable, Sendable {
    var identity: SIMD2<Int64>
    var flags: SIMD4<UInt32>
    var previous: SIMD4<Float>
    var current: SIMD4<Float>
    var velocity: SIMD4<Float>
    var collision: SIMD4<Float>
    var filter: SIMD4<UInt32> // kategoria, maska, reserved, reserved

    init(_ segment: NativeSolverSegment) {
        identity = SIMD2(Int64(segment.id), Int64(segment.ownerID ?? 0))
        flags = SIMD4(segment.isKinematic ? 1 : 0, segment.ownerID == nil ? 0 : 1,
                      segment.allowedSide == nil ? 0 : 1, 0)
        previous = SIMD4(segment.previousA.x, segment.previousA.y, segment.previousB.x, segment.previousB.y)
        current = SIMD4(segment.currentA.x, segment.currentA.y, segment.currentB.x, segment.currentB.y)
        velocity = SIMD4(segment.linearVelocity.x, segment.linearVelocity.y, segment.angularVelocity, 0)
        collision = SIMD4(segment.allowedSide ?? 0, 0, 0, 0)
        filter = NativeMetalFilter.pack(segment.filter)
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
    var counts: SIMD4<UInt32> // candidates, contacts, cache, reserved
    var cache: SIMD4<UInt32> // hits, resets, invalidationCount, k (kandydaci na obiekt)
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

/// Wynik hit-testu jednego punktu: zwycięzca to największa para (warstwa, ObjectID); `found` 0 to puste miejsce.
struct NativeHitTestResult: Equatable, Sendable {
    var identity: UInt64
    var layer: UInt32
    var found: UInt32
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
package struct NativeMetalSnapshot: Sendable {
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
    let hitTests: [SIMD2<Float>]

    package init(input: NativeSolverInput, previous: NativeMetalSnapshot? = nil) {
        let publicSettings = input.publicSettings
        self.publicSettings = publicSettings
        hitTests = input.hitTests
        configuration = input.configuration
        sourceBubbles = input.bubbles
        sourceSegments = input.segments
        previousBubbles = previous?.sourceBubbles
        previousSegments = previous?.sourceSegments
        // Jedno wyszukiwanie poprzedniego rekordu na bańkę służy zmianom i przesunięciom; słownik trzyma tylko indeks.
        let previousBubbleList = previous?.sourceBubbles ?? []
        let previousByID = Dictionary(uniqueKeysWithValues: previousBubbleList.indices.lazy.map { (previousBubbleList[$0].id, $0) })
        let previousProperties = previous?.publicSettings?.properties
        var changes: [NativeMetalBubbleChange] = []
        var remaps: [NativeMetalBubbleRemap] = []
        for (index, bubble) in input.bubbles.enumerated() {
            let existing = previousByID[bubble.id]
            let unchanged = existing.map { previousBubbleList[$0] == bubble } ?? false
            let properties = publicSettings?.properties[bubble.id]
            if !unchanged || properties != previousProperties?[bubble.id] {
                var value = NativeMetalBubble(bubble)
                if let properties {
                    value.publicFlags = properties.flags; value.material = properties.material; value.resources = properties.resources
                    // GPU nie rozwiązuje po ID zasobu; wolny lane niesie stabilną
                    // restitucję bez współdzielenia bufora deformacji konturu.
                    value.resources.x = UInt64(properties.restitution.bitPattern)
                    value.eventData = properties.eventData
                    value.filter = NativeMetalFilter.pack(properties.filter, layer: properties.layer)
                    value.deformation = SIMD4(0, 0, properties.speedLimits.x, properties.speedLimits.y)
                }
                changes.append(.init(index: index, value: value))
            }
            if unchanged, let existing, existing != index {
                remaps.append(.init(sourceIndex: existing, destinationIndex: index))
            }
        }
        bubbleChanges = changes
        bubbleRemaps = remaps
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
    /// Początek kodowania kroku w zegarze `DispatchTime.uptimeNanoseconds`, jak czas klatki w benchmarku;
    /// różnica względem początku `advance` to przygotowanie wejścia po stronie CPU.
    public var encodingStartNanoseconds: UInt64 = 0
    /// Koniec oczekiwania na GPU w tym samym zegarze; różnica do powrotu z `advance` to odczyt i publikacja kroku.
    public var waitingEndNanoseconds: UInt64 = 0
    /// Łączny czas ukończonego command buffera; bez pozornych czasów osobnych dispatchy.
    public var stageGPUMilliseconds: [String: Double] = [:]
    /// Opcjonalne liczniki rzeczywiście wykonanych work-itemów, używane w profilu przepustowości.
    public var stageGPUWorkItemCounts: [String: Int] = [:]

    public init() {}
}
