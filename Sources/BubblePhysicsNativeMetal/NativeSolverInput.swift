import Foundation
import BubblePhysicsModel

// Neutralna granica solvera: wejście i wynik kroku bez typów modułu diagnostycznego.
// Od niej zależy wydajność kroku, adapter diagnostyczny i każdy późniejszy kernel.

package struct NativeSolverBubbleID: Hashable, Comparable, Sendable {
    package var rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }
    package static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

extension SIMD2 where Scalar == Float {
    var isFiniteVector: Bool { x.isFinite && y.isFinite }
    var euclideanLength: Float { (x * x + y * y).squareRoot() }
}

package struct NativeSolverBubble: Equatable, Sendable {
    package var id: NativeSolverBubbleID
    package var center: SIMD2<Float>
    package var previousCenter: SIMD2<Float>
    package var velocity: SIMD2<Float>
    package var mass: Float
    package var inverseMass: Float
    package var targetRadius: Float
    package var stiffness: Float
    package var rotation: Float
    package var angularVelocity: Float

    package init(id: NativeSolverBubbleID, center: SIMD2<Float>, previousCenter: SIMD2<Float>? = nil,
                 velocity: SIMD2<Float> = .zero, mass: Float, inverseMass: Float? = nil, targetRadius: Float,
                 stiffness: Float = 1, rotation: Float = 0, angularVelocity: Float = 0) {
        self.id = id
        self.center = center
        self.previousCenter = previousCenter ?? center
        self.velocity = velocity
        self.mass = mass
        self.inverseMass = inverseMass ?? 1 / mass
        self.targetRadius = targetRadius
        self.stiffness = stiffness
        self.rotation = rotation
        self.angularVelocity = angularVelocity
    }

    var isFiniteState: Bool {
        center.isFiniteVector && previousCenter.isFiniteVector && velocity.isFiniteVector
            && rotation.isFinite && angularVelocity.isFinite
    }
}

package struct NativeSolverSegment: Equatable, Sendable {
    package var id: Int
    package var previousA: SIMD2<Float>
    package var previousB: SIMD2<Float>
    package var currentA: SIMD2<Float>
    package var currentB: SIMD2<Float>
    package var linearVelocity: SIMD2<Float> = .zero
    package var angularVelocity: Float = 0
    package var isKinematic = false
    package var ownerID: Int?
    /// `nil` oznacza segment dwustronny; w przeciwnym razie znak dozwolonej strony (−1 albo 1).
    package var allowedSide: Float?

    package init(id: Int, previousA: SIMD2<Float>, previousB: SIMD2<Float>, currentA: SIMD2<Float>,
                 currentB: SIMD2<Float>, linearVelocity: SIMD2<Float> = .zero, angularVelocity: Float = 0,
                 isKinematic: Bool = false, ownerID: Int? = nil, allowedSide: Float? = nil) {
        self.id = id
        self.previousA = previousA; self.previousB = previousB
        self.currentA = currentA; self.currentB = currentB
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
        self.isKinematic = isKinematic
        self.ownerID = ownerID
        self.allowedSide = allowedSide
    }

    /// Statyczny, dwustronny segment bez ruchu (krawędź statycznej bryły).
    package static func fixed(id: Int, a: SIMD2<Float>, b: SIMD2<Float>, ownerID: Int? = nil) -> Self {
        .init(id: id, previousA: a, previousB: b, currentA: a, currentB: b, ownerID: ownerID)
    }
}

package struct NativeSolverConfiguration: Equatable, Sendable {
    package var timeStep: Float
    package var linearDamping: Float
    package var angularDamping: Float
    package var contactTolerance: Float
    package var separationTolerance: Float
    package var positionTolerance: Float
    package var maxContourSegmentLength: Float
    package var deformationRecoveryRate: Float
    package var contactStiffness: Float
    package var contactDamping: Float
    package var contourSurfaceTension: Float

    package init(timeStep: Float = 1 / 60, linearDamping: Float = 1.5, angularDamping: Float = 2,
                 contactTolerance: Float = 0.001, separationTolerance: Float = 0.002,
                 positionTolerance: Float = 0.0001, maxContourSegmentLength: Float = 8,
                 deformationRecoveryRate: Float = 12, contactStiffness: Float = 120,
                 contactDamping: Float = 8, contourSurfaceTension: Float = 20) {
        self.timeStep = timeStep
        self.linearDamping = linearDamping
        self.angularDamping = angularDamping
        self.contactTolerance = contactTolerance
        self.separationTolerance = separationTolerance
        self.positionTolerance = positionTolerance
        self.maxContourSegmentLength = maxContourSegmentLength
        self.deformationRecoveryRate = deformationRecoveryRate
        self.contactStiffness = contactStiffness
        self.contactDamping = contactDamping
        self.contourSurfaceTension = contourSurfaceTension
    }

    /// Te same wartości zastępcze co konfiguracja diagnostyczna, żeby wynik solvera się nie zmienił.
    package var sanitized: Self {
        func nonnegative(_ value: Float, _ fallback: Float) -> Float { value.isFinite && value >= 0 ? value : fallback }
        func positive(_ value: Float, _ fallback: Float) -> Float { value.isFinite && value > 0 ? value : fallback }
        var value = self
        value.timeStep = positive(timeStep, 1 / 60)
        value.contactTolerance = nonnegative(contactTolerance, 0.001)
        value.separationTolerance = nonnegative(separationTolerance, 0.002)
        value.positionTolerance = nonnegative(positionTolerance, 0.0001)
        value.linearDamping = nonnegative(linearDamping, 1.5)
        value.angularDamping = nonnegative(angularDamping, 2)
        value.maxContourSegmentLength = positive(maxContourSegmentLength, 8)
        value.deformationRecoveryRate = nonnegative(deformationRecoveryRate, 12)
        value.contactStiffness = positive(contactStiffness, 120)
        value.contactDamping = nonnegative(contactDamping, 8)
        value.contourSurfaceTension = nonnegative(contourSurfaceTension, 20)
        return value
    }
}

/// Wejście jednego kroku solvera. Budowane liniowo z obiektów świata; bez `ReferenceWorld`.
package struct NativeSolverInput: Sendable {
    package var configuration: NativeSolverConfiguration
    package var bubbles: [NativeSolverBubble]
    package var segments: [NativeSolverSegment]
    /// Ustawienia ścieżki publicznej gry (własności, zdarzenia, bryły); diagnostyka zostawia `nil`.
    var publicSettings: NativePublicSettings?

    package init(configuration: NativeSolverConfiguration = .init(), bubbles: [NativeSolverBubble] = [],
                 segments: [NativeSolverSegment] = []) {
        self.init(configuration: configuration, bubbles: bubbles, segments: segments, publicSettings: nil)
    }

    init(configuration: NativeSolverConfiguration, bubbles: [NativeSolverBubble],
         segments: [NativeSolverSegment], publicSettings: NativePublicSettings?) {
        self.configuration = configuration
        self.bubbles = bubbles
        self.segments = segments
        self.publicSettings = publicSettings
    }
}

package enum NativeSolverContactKind: Sendable, Equatable { case bubbleBubble, bubbleSegment }

package struct NativeSolverContact: Sendable, Equatable {
    package var id: UInt64
    package var kind: NativeSolverContactKind
    package var bubbleA: NativeSolverBubbleID
    package var bubbleB: NativeSolverBubbleID?
    package var segment: Int?
    package var normal: SIMD2<Float>
    package var pointQ: SIMD2<Float>
    package var penetration: Float
    package var allowedSide: Float?
    package var accumulatedCompression: Float
    package var age: Int
}

package struct NativeSolverReport: Sendable, Equatable {
    package var iterations = 0
    package var maximumPenetration: Float = 0
    package var converged = false
    package var didReachIterationLimit = false
    package var positionCorrectionCount = 0
    package var deformationCount = 0
    package var initialResidualNorm: Float = 0
    package var finalResidualNorm: Float = 0
    package var maximumRelativeDeformation: Float = 0
    package var candidatePairCount = 0
    package var generatedContactCount = 0
    package var persistentContactCount = 0
    package var toiTestCount = 0
    package var sideCorrectionCount = 0
    package var totalMilliseconds: Double = 0
    package var hasNonFiniteState = false
}

/// Wynik jednego kroku solvera, w typach neutralnych.
package struct NativeSolverFrame {
    package var bubbles: [NativeSolverBubble]
    package var contacts: [NativeSolverContact]
    package var report: NativeSolverReport
    package var telemetry: NativeMetalFrameTelemetry
    package var profile = NativeMetalFrameProfile()
    package var contours: [NativeSolverBubbleID: [SIMD2<Float>]] = [:]
    package var renderData: [SIMD4<Float>] = []
    package var effectiveRadii: [NativeSolverBubbleID: Float] = [:]
    /// AABB zdeformowanego konturu po kroku (min.xy, max.xy), liczony w kernelu; bez odczytu konturu na CPU.
    package var bubbleBounds: [NativeSolverBubbleID: SIMD4<Float>] = [:]
    package var isComplete = false
    package var regionRemovals: Set<NativeSolverBubbleID> = []
    package var regionWraps: Set<NativeSolverBubbleID> = []
    package var events: [WorldEvent] = []
    package var eventOverflow = WorldEventOverflow()
}

/// Szew między solverem a jego użytkownikami (runner diagnostyczny, fałszywe wykonawcy w testach).
@MainActor
package protocol NativeMetalFrameExecuting {
    func executeFrame(input: NativeSolverInput, scenarioStep: Int) async throws -> NativeSolverFrame
    func acknowledgePublication()
}

extension NativeMetalFrameExecuting {
    package func acknowledgePublication() {}
}

package enum NativeMetalWorldError: Error {
    case unavailable, invalidFrame, frameInFlight, nonFinite, guardFailure
}

package struct NativeMetalSafetyFailure: Error {
    package let reason: NativeMetalWorldError
    package let telemetry: NativeMetalFrameTelemetry
    package let profile: NativeMetalFrameProfile
    package init(reason: NativeMetalWorldError, telemetry: NativeMetalFrameTelemetry, profile: NativeMetalFrameProfile) {
        self.reason = reason; self.telemetry = telemetry; self.profile = profile
    }
}
