import Metal
import BubblePhysicsReference

@MainActor
protocol NativeMetalFrameExecuting {
    func executeFrame(world: ReferenceWorld, scenarioStep: Int) async throws -> NativeMetalWorldFrame
}

struct NativeMetalWorldFrame {
    var bubbles: [ReferenceBubble]
    var contacts: [ReferenceContact]
    var report: ReferenceWorldStepReport
    var telemetry: NativeMetalFrameTelemetry
    var profile = NativeMetalFrameProfile()
    var isComplete = false
}

enum NativeMetalWorldError: Error {
    case unavailable, invalidFrame, frameInFlight, nonFinite, guardFailure
}

struct NativeMetalSafetyFailure: Error {
    let reason: NativeMetalWorldError
    let telemetry: NativeMetalFrameTelemetry
    let profile: NativeMetalFrameProfile
}

/// Do czasu ukończenia konturów wynik GPU jest diagnostyczny;
/// świat otrzymuje atomowo pełną klatkę CPU.
@MainActor
public final class NativeMetalWorldRunner {
    public let configuration: NativeMetalConfiguration
    public private(set) var telemetry = NativeMetalFrameTelemetry()
    public private(set) var profile = NativeMetalFrameProfile()
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
            // Task 6 dostarczy kontury i kompletną publikację świata.
            world = original
            return cpuFrame(world: &world, reason: "invalidFrame", diagnostics: frame.telemetry)
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
