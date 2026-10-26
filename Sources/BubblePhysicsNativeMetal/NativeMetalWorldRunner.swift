import Metal
import BubblePhysicsModel
@_spi(ReferenceMetal) import BubblePhysicsReference

@MainActor
protocol NativeMetalFrameExecuting {
    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame
    func acknowledgePublication()
}

extension NativeMetalFrameExecuting {
    func acknowledgePublication() {}
}

struct NativeMetalWorldFrame {
    var bubbles: [ReferenceBubble]
    var contacts: [ReferenceContact]
    var report: ReferenceWorldStepReport
    var telemetry: NativeMetalFrameTelemetry
    var profile = NativeMetalFrameProfile()
    var contours: [ReferenceBubbleID: [ReferenceVector2]] = [:]
    var renderData: [SIMD4<Float>] = []
    var effectiveRadii: [ReferenceBubbleID: Float] = [:]
    var isComplete = false
    var regionRemovals: Set<ReferenceBubbleID> = []
    var regionWraps: Set<ReferenceBubbleID> = []
    var events: [WorldEvent] = []
    var eventOverflow = WorldEventOverflow()
    var selections: [UInt64: ObjectID?] = [:]
}

package struct NativeSelectionRequest: Sendable {
    package let number: UInt64
    package let point: WorldPoint
    package init(number: UInt64, point: WorldPoint) {
        self.number = number
        self.point = point
    }
}

enum NativeMetalWorldError: Error {
    case unavailable, invalidFrame, frameInFlight, nonFinite, guardFailure
}

struct NativeMetalSafetyFailure: Error {
    let reason: NativeMetalWorldError
    let telemetry: NativeMetalFrameTelemetry
    let profile: NativeMetalFrameProfile
}

/// Publikuje atomowo pełną klatkę GPU albo wykonuje pełny krok CPU.
@MainActor
public final class NativeMetalWorldRunner {
    public let configuration: NativeMetalConfiguration
    public private(set) var telemetry = NativeMetalFrameTelemetry()
    public private(set) var profile = NativeMetalFrameProfile()
    public private(set) var contours: [ReferenceBubbleID: [ReferenceVector2]] = [:]
    public private(set) var renderData: [SIMD4<Float>] = []
    private let executor: (any NativeMetalFrameExecuting)?
    private var inFlight = false

    public convenience init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                             configuration: NativeMetalConfiguration = .default) {
        guard let device, let solver = try? NativeMetalSolver(device: device, configuration: configuration) else { return nil }
        self.init(executor: solver, configuration: configuration)
    }

    init(executor: (any NativeMetalFrameExecuting)?, configuration: NativeMetalConfiguration = .default) {
        self.executor = executor
        self.configuration = configuration.sanitized
    }

    public func step(world: inout ReferenceWorld, scenarioStep: Int) async -> ReferenceWorldStepReport {
        profile = NativeMetalFrameProfile()
        guard !inFlight else {
            return cpuFrame(world: &world, reason: .frameInFlight)
        }
        guard let executor else {
            return cpuFrame(world: &world, reason: .unavailable)
        }
        inFlight = true
        defer { inFlight = false }
        let original = world
        do {
            // Executor otrzymuje wartość świata, nigdy referencję do publikacji.
            let frame = try await executor.executeFrame(world: world, scenarioStep: scenarioStep)
            profile = frame.profile
            guard !frame.telemetry.didEncounterNonFinite, !frame.report.hasNonFiniteState,
                  frame.bubbles.allSatisfy({ $0.center.isFinite && $0.previousCenter.isFinite && $0.velocity.isFinite
                      && $0.rotation.isFinite && $0.angularVelocity.isFinite }),
                  frame.contacts.allSatisfy({ $0.normal.isFinite && $0.pointQ.isFinite
                      && $0.penetration.isFinite && $0.accumulatedCompression.isFinite })
            else {
                world = original
                return cpuFrame(world: &world, reason: "nonFinite", diagnostics: frame.telemetry)
            }
            guard frame.isComplete, frame.bubbles.map(\.id) == original.bubbles.map(\.id),
                  frame.telemetry.backend == .nativeMetal, frame.telemetry.fallbackReason == nil,
                  frame.contours.count == frame.bubbles.count, frame.renderData.count == frame.bubbles.count,
                  frame.bubbles.enumerated().allSatisfy({ index, bubble in
                      guard let points = frame.contours[bubble.id], points.count >= 32,
                            points.allSatisfy(\.isFinite) else { return false }
                      return frame.renderData[index] == SIMD4(bubble.center.x, bubble.center.y, bubble.targetRadius, bubble.rotation)
                  })
            else {
                world = original
                return cpuFrame(world: &world, reason: "invalidFrame", diagnostics: frame.telemetry)
            }
            world.publishPreparedFrame(bubbles: frame.bubbles, contacts: frame.contacts, contours: frame.contours)
            executor.acknowledgePublication()
            contours = frame.contours
            renderData = frame.renderData
            telemetry = frame.telemetry
            return frame.report
        } catch let failure as NativeMetalSafetyFailure {
            world = original
            profile = failure.profile
            return cpuFrame(world: &world, reason: String(describing: failure.reason), diagnostics: failure.telemetry)
        } catch {
            world = original
            return cpuFrame(world: &world, reason: String(describing: error))
        }
    }

    private func cpuFrame(world: inout ReferenceWorld, reason: NativeMetalWorldError) -> ReferenceWorldStepReport {
        cpuFrame(world: &world, reason: String(describing: reason))
    }

    private func cpuFrame(world: inout ReferenceWorld, reason: String,
                          diagnostics: NativeMetalFrameTelemetry? = nil) -> ReferenceWorldStepReport {
        // Region publikacji jest synchroniczny: dokładnie jeden pełny krok
        // na oryginalnym świecie oraz aktualizacja telemetrii bez await.
        let report = world.step()
        contours = [:]
        renderData = []
        telemetry = .init(backend: .cpu, commandBufferCount: diagnostics?.commandBufferCount ?? 0,
            encoderCount: diagnostics?.encoderCount ?? 0, cacheHitCount: diagnostics?.cacheHitCount ?? 0,
            cacheResetCount: diagnostics?.cacheResetCount ?? 0, contactCount: world.contacts.contacts.count,
            didEncounterNonFinite: report.hasNonFiniteState || diagnostics?.didEncounterNonFinite == true || reason == "nonFinite",
            fallbackReason: reason, gpuMilliseconds: diagnostics?.gpuMilliseconds ?? 0,
            solverIterationCount: diagnostics?.solverIterationCount ?? 0,
            ccdCandidateCount: diagnostics?.ccdCandidateCount ?? 0,
            guardCorrectionCount: diagnostics?.guardCorrectionCount ?? 0,
            cacheInvalidationCount: diagnostics?.cacheInvalidationCount ?? 0)
        return report
    }
}
