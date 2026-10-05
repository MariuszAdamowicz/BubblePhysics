import BubblePhysicsReference

// ABI uses SIMD lanes only: every record is 16-byte aligned. IDs are signed
// 64-bit values rather than truncated GPU indices; optional IDs use flag bits.
struct ReferenceMetalBubble: Equatable, Sendable {
    let identity: SIMD2<Int64> // id, reserved
    let physical: SIMD4<Float> // mass, inverse mass, target radius, stiffness
    let angular: SIMD4<Float> // rotation, angular velocity, reserved, reserved

    init(_ bubble: ReferenceBubble) {
        identity = SIMD2(Int64(bubble.id.rawValue), 0)
        physical = SIMD4(bubble.mass, bubble.inverseMass, bubble.targetRadius, bubble.stiffness)
        angular = SIMD4(bubble.rotation, bubble.angularVelocity, 0, 0)
    }
}

struct ReferenceMetalSegment: Equatable, Sendable {
    let identity: SIMD2<Int64> // id, owner id (valid when flags.y == 1)
    let flags: SIMD4<UInt32> // kinematic, has owner, one-sided, reserved
    let previous: SIMD4<Float> // previous A.xy, B.xy
    let current: SIMD4<Float> // current A.xy, B.xy
    let velocity: SIMD4<Float> // linear xy, angular, reserved
    let collision: SIMD4<Float> // allowed side, reserved

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

struct ReferenceMetalContact: Equatable, Sendable {
    let identity: SIMD2<UInt64> // contact id, optional-field bit mask
    let bubbles: SIMD2<Int64> // A id, B id
    let segmentAndAge: SIMD2<Int64>
    let geometry: SIMD4<Float> // normal.xy, pointQ.xy
    let timing: SIMD4<Float> // penetration, TOI, allowed side, contour half length
    let compression: SIMD4<Float> // accumulated, A, B, pressure
    let response: SIMD4<Float> // effective stiffness, reserved

    init(_ contact: ReferenceContact) {
        var mask: UInt64 = contact.kind == .bubbleSegment ? 1 : 0
        if contact.bubbleB != nil { mask |= 2 }
        if contact.segment != nil { mask |= 4 }
        if contact.timeOfImpact != nil { mask |= 8 }
        if contact.allowedSide != nil { mask |= 16 }
        if contact.contourHalfLength != nil { mask |= 32 }
        identity = SIMD2(contact.id.rawValue, mask)
        bubbles = SIMD2(Int64(contact.bubbleA.rawValue), Int64(contact.bubbleB?.rawValue ?? 0))
        segmentAndAge = SIMD2(Int64(contact.segment?.rawValue ?? 0), Int64(contact.age))
        geometry = SIMD4(contact.normal.x, contact.normal.y, contact.pointQ.x, contact.pointQ.y)
        timing = SIMD4(contact.penetration, contact.timeOfImpact ?? 0, contact.allowedSide ?? 0, contact.contourHalfLength ?? 0)
        compression = SIMD4(contact.accumulatedCompression, contact.compressionA, contact.compressionB, contact.pressure)
        response = SIMD4(contact.effectiveStiffness, 0, 0, 0)
    }
}

struct ReferenceMetalComponent: Equatable, Sendable {
    let ranges: SIMD4<UInt64> // bubble start/count, contact start/count
}

/// Immutable SoA frame input; mutable solver vectors live in separate buffers.
struct ReferenceMetalSnapshot: Equatable, Sendable {
    let configuration: ReferenceConfiguration
    let bubbles: [ReferenceMetalBubble]
    let centers: [SIMD2<Float>]
    let previousCenters: [SIMD2<Float>]
    let velocities: [SIMD2<Float>]
    let segments: [ReferenceMetalSegment]
    let contacts: [ReferenceMetalContact]

    /// Optional contacts let a prepared contact phase become the next immutable
    /// input without mutating the CPU world's privately owned contact set.
    init(world: ReferenceWorld, contacts: [ReferenceContact]? = nil) {
        configuration = world.configuration
        let sorted = world.bubbles.sorted { $0.id < $1.id }
        bubbles = sorted.map(ReferenceMetalBubble.init)
        centers = sorted.map { SIMD2($0.center.x, $0.center.y) }
        previousCenters = sorted.map { SIMD2($0.previousCenter.x, $0.previousCenter.y) }
        velocities = sorted.map { SIMD2($0.velocity.x, $0.velocity.y) }
        segments = world.segments.sorted { $0.id < $1.id }.map(ReferenceMetalSegment.init)
        self.contacts = (contacts ?? world.contacts.contacts).sorted { $0.id < $1.id }.map(ReferenceMetalContact.init)
    }
}

struct ReferenceMetalFrameOutput: Equatable, Sendable {
    let centers: [SIMD2<Float>]
    let velocities: [SIMD2<Float>]
}

// Shared Swift/MSL control record. Only GPU kernels mutate it during PCG.
// A fixed dispatch schedule continues after convergence; active freezes state.
struct ReferenceMetalPCGControl {
    var state: SIMD4<UInt32> // active, iteration count, non-finite, rejected initial norm
    var norms: SIMD4<Float> // initial norm, final norm, threshold, reserved
    var recurrence: SIMD4<Float> // r·z, beta, reserved, reserved
}

struct ReferenceMetalWorldParameters {
    var counts: SIMD4<UInt32>
    var physics: SIMD4<Float>
    var damping: SIMD4<Float>
    var tolerances: SIMD4<Float>
    var shape: SIMD4<Float>
    var limits: SIMD4<UInt32>
}

struct ReferenceMetalWorldControl {
    var solverCounts: SIMD4<UInt32>
    var solverQuality: SIMD4<Float>
    var solverComponents: SIMD4<Float>
    var work: SIMD4<UInt32>
    var events: SIMD4<UInt32>
    var failure: SIMD4<UInt32>
}
