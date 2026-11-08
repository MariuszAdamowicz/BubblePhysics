import Metal
import BubblePhysicsNativeMetal
import BubblePhysicsReference

/// Tłumaczy świat diagnostyczny (`ReferenceWorld`) na neutralne wejście solvera i wynik z powrotem na typy Reference.
/// Tylko diagnostyka zna oba światy; produkcyjny solver nie zna typów Reference.
enum ReferenceSolverInputAdapter {
    static func input(from world: ReferenceWorld) -> NativeSolverInput {
        NativeSolverInput(configuration: .init(world.configuration),
                          bubbles: world.bubbles.map(NativeSolverBubble.init),
                          segments: world.segments.map(NativeSolverSegment.init))
    }

    static func worldFrame(from frame: NativeSolverFrame) -> NativeMetalWorldFrame { .init(frame) }
}

extension NativeSolverBubble {
    init(_ bubble: ReferenceBubble) {
        self.init(id: .init(rawValue: bubble.id.rawValue), center: SIMD2(bubble.center.x, bubble.center.y),
                  previousCenter: SIMD2(bubble.previousCenter.x, bubble.previousCenter.y),
                  velocity: SIMD2(bubble.velocity.x, bubble.velocity.y), mass: bubble.mass,
                  inverseMass: bubble.inverseMass, targetRadius: bubble.targetRadius, stiffness: bubble.stiffness,
                  rotation: bubble.rotation, angularVelocity: bubble.angularVelocity)
    }
}

extension NativeSolverSegment {
    init(_ segment: ReferenceSegment) {
        self.init(id: segment.id.rawValue,
                  previousA: SIMD2(segment.previousA.x, segment.previousA.y),
                  previousB: SIMD2(segment.previousB.x, segment.previousB.y),
                  currentA: SIMD2(segment.currentA.x, segment.currentA.y),
                  currentB: SIMD2(segment.currentB.x, segment.currentB.y),
                  linearVelocity: SIMD2(segment.linearVelocity.x, segment.linearVelocity.y),
                  angularVelocity: segment.angularVelocity, isKinematic: segment.motion == .kinematic,
                  ownerID: segment.ownerID, allowedSide: segment.collisionMode.allowedSide)
    }
}

extension NativeSolverConfiguration {
    init(_ configuration: ReferenceConfiguration) {
        self.init(timeStep: configuration.timeStep, linearDamping: configuration.linearDamping,
                  angularDamping: configuration.angularDamping, contactTolerance: configuration.contactTolerance,
                  separationTolerance: configuration.separationTolerance,
                  positionTolerance: configuration.positionTolerance,
                  maxContourSegmentLength: configuration.maxContourSegmentLength,
                  deformationRecoveryRate: configuration.deformationRecoveryRate,
                  contactStiffness: configuration.contactStiffness, contactDamping: configuration.contactDamping,
                  contourSurfaceTension: configuration.contourSurfaceTension)
    }
}

extension NativeMetalSnapshot {
    init(world: ReferenceWorld, previous: NativeMetalSnapshot? = nil) {
        self.init(input: ReferenceSolverInputAdapter.input(from: world), previous: previous)
    }
}

extension NativeMetalWorldFrame {
    init(_ frame: NativeSolverFrame) {
        func vector(_ value: SIMD2<Float>) -> ReferenceVector2 { .init(x: value.x, y: value.y) }
        func bubbleID(_ id: NativeSolverBubbleID) -> ReferenceBubbleID { .init(rawValue: id.rawValue) }
        let bubbles = frame.bubbles.map { source -> ReferenceBubble in
            // Wynik solvera może zawierać wartości nieskończone; runner ma je odrzucić, więc bez walidacji konstruktora.
            var bubble = try! ReferenceBubble(id: bubbleID(source.id), center: .zero, mass: 1, targetRadius: 1)
            bubble.center = vector(source.center)
            bubble.previousCenter = vector(source.previousCenter)
            bubble.velocity = vector(source.velocity)
            bubble.mass = source.mass
            bubble.inverseMass = source.inverseMass
            bubble.targetRadius = source.targetRadius
            bubble.stiffness = source.stiffness
            bubble.rotation = source.rotation
            bubble.angularVelocity = source.angularVelocity
            return bubble
        }
        let contacts = frame.contacts.map { contact in
            ReferenceContact(id: .init(rawValue: contact.id),
                kind: contact.kind == .bubbleBubble ? .bubbleBubble : .bubbleSegment,
                bubbleA: bubbleID(contact.bubbleA), bubbleB: contact.bubbleB.map(bubbleID),
                segment: contact.segment.map { .init(rawValue: $0) },
                normal: vector(contact.normal), pointQ: vector(contact.pointQ), penetration: contact.penetration,
                allowedSide: contact.allowedSide, accumulatedCompression: contact.accumulatedCompression,
                age: contact.age)
        }
        let source = frame.report
        let report = ReferenceWorldStepReport(solver: .init(iterations: source.iterations,
            maximumPenetration: source.maximumPenetration, converged: source.converged,
            didReachIterationLimit: source.didReachIterationLimit,
            positionCorrectionCount: source.positionCorrectionCount, deformationCount: source.deformationCount,
            initialResidualNorm: source.initialResidualNorm, finalResidualNorm: source.finalResidualNorm,
            maximumRelativeDeformation: source.maximumRelativeDeformation),
            candidatePairCount: source.candidatePairCount, generatedContactCount: source.generatedContactCount,
            persistentContactCount: source.persistentContactCount, toiTestCount: source.toiTestCount,
            sideCorrectionCount: source.sideCorrectionCount, ccdBudgetExhaustionCount: 0, predictionMilliseconds: 0,
            broadPhaseMilliseconds: 0, contactMilliseconds: 0, solverMilliseconds: 0,
            totalMilliseconds: source.totalMilliseconds, hasNonFiniteState: source.hasNonFiniteState)
        self.init(bubbles: bubbles, contacts: contacts, report: report, telemetry: frame.telemetry,
            profile: frame.profile,
            contours: Dictionary(uniqueKeysWithValues: frame.contours.map { (bubbleID($0.key), $0.value.map(vector)) }),
            renderData: frame.renderData,
            effectiveRadii: Dictionary(uniqueKeysWithValues: frame.effectiveRadii.map { (bubbleID($0.key), $0.value) }),
            isComplete: frame.isComplete, regionRemovals: Set(frame.regionRemovals.map(bubbleID)),
            regionWraps: Set(frame.regionWraps.map(bubbleID)), events: frame.events,
            eventOverflow: frame.eventOverflow)
    }
}

extension NativeMetalSolver {
    /// Ostatnia opublikowana klatka w typach diagnostycznych.
    var publishedFrame: NativeMetalWorldFrame? { publishedSolverFrame.map(NativeMetalWorldFrame.init) }

    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        .init(try await executeFrame(input: ReferenceSolverInputAdapter.input(from: world), scenarioStep: scenarioStep))
    }

    func executeFrame(snapshot: NativeMetalSnapshot, scenarioStep: Int) async throws -> NativeMetalWorldFrame {
        .init(try await executeSnapshot(snapshot, scenarioStep: scenarioStep, commandBuffer: nil, beforeCommit: nil))
    }
}
