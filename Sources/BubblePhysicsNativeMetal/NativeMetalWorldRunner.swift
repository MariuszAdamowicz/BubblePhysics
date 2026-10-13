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
    case unavailable, invalidFrame, frameInFlight
}

/// Do czasu ukończenia solvera kontaktów predykcja GPU jest diagnostyczna;
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
        do {
            // Executor otrzymuje wartość świata, nigdy referencję do publikacji.
            let frame = try await executor.executeFrame(world: world, scenarioStep: scenarioStep)
            profile = frame.profile
            // Task 2 dostarcza predykcję, nie pełne rozwiązanie klatki.
            return cpuFrame(world: &world, reason: .invalidFrame)
        } catch {
            return cpuFrame(world: &world, reason: String(describing: error))
        }
    }

    private func cpuFrame(world: inout ReferenceWorld, reason: NativeMetalWorldError) -> ReferenceWorldStepReport {
        cpuFrame(world: &world, reason: String(describing: reason))
    }

    private func cpuFrame(world: inout ReferenceWorld, reason: String) -> ReferenceWorldStepReport {
        // Region publikacji jest synchroniczny: dokładnie jeden pełny krok
        // na oryginalnym świecie oraz aktualizacja telemetrii bez await.
        let report = world.step()
        telemetry = .init(backend: .cpu, contactCount: world.contacts.contacts.count,
                          didEncounterNonFinite: report.hasNonFiniteState, fallbackReason: reason)
        return report
    }
}
