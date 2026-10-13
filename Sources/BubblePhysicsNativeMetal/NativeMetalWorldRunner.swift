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
}

enum NativeMetalWorldError: Error {
    case unavailable, invalidFrame, frameInFlight
}

/// Izolowany kontrakt backendu. Do czasu wdrożenia runtime każda próba
/// kończy się pełną klatką CPU; żaden stan roboczy GPU nie jest publikowany.
@MainActor
public final class NativeMetalWorldRunner {
    public let configuration: NativeMetalConfiguration
    public private(set) var telemetry = NativeMetalFrameTelemetry()
    private let executor: (any NativeMetalFrameExecuting)?
    private var inFlight = false

    public convenience init?(device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                             configuration: NativeMetalConfiguration = .default) {
        guard device != nil else { return nil }
        self.init(executor: nil, configuration: configuration)
    }

    init(executor: (any NativeMetalFrameExecuting)?, configuration: NativeMetalConfiguration = .default) {
        self.executor = executor
        self.configuration = configuration.sanitized
    }

    public func step(world: inout ReferenceWorld, scenarioStep: Int) async -> ReferenceWorldStepReport {
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
            _ = try await executor.executeFrame(world: world, scenarioStep: scenarioStep)
            // Task 1 nie ma jeszcze runtime ani walidatora pełnej klatki GPU.
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
