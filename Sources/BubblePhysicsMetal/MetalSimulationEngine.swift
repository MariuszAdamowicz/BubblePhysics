import BubblePhysics

public struct MetalEngineStepResult: Equatable, Sendable {
    public let snapshot: MetalWorldSnapshot
    public let diagnostics: SimulationBackendDiagnostics
    public let appliedCommandCount: Int
    public let hasNonFiniteState: Bool
}

public final class MetalSimulationEngine: @unchecked Sendable {
    private let solver: MetalBubbleSolver?

    public init(solver: MetalBubbleSolver? = MetalBubbleSolver()) {
        self.solver = solver
    }

    public func step(world: inout BubbleWorld) async -> MetalEngineStepResult {
        guard let solver else { return cpuFallback(world: &world) }

        do {
            var snapshot = MetalWorldSnapshot(world: world)
            let frame = try await solver.solveFrame(
                snapshot: snapshot,
                gravity: world.gravity,
                bounds: world.bounds,
                configuration: world.configuration
            )
            snapshot = snapshot.replacingParticles(frame.particles)
            let interactions = try await solver.solveInteractions(snapshot: snapshot, configuration: world.configuration)
            snapshot = snapshot.replacingParticles(interactions.particles)
            return MetalEngineStepResult(
                snapshot: snapshot,
                diagnostics: SimulationBackendDiagnostics(
                    backend: .metal,
                    didFallbackToCPU: false,
                    particleCount: snapshot.particles.count,
                    candidatePairCount: frame.candidatePairCount,
                    contactCount: frame.candidatePairCount,
                    didOverflow: false
                ),
                appliedCommandCount: 0,
                hasNonFiniteState: containsNonFiniteState(snapshot)
            )
        } catch {
            return cpuFallback(world: &world)
        }
    }

    private func cpuFallback(world: inout BubbleWorld) -> MetalEngineStepResult {
        let report = world.step()
        let snapshot = MetalWorldSnapshot(world: world)
        return MetalEngineStepResult(
            snapshot: snapshot,
            diagnostics: SimulationBackendDiagnostics(
                backend: .cpu,
                didFallbackToCPU: true,
                particleCount: snapshot.particles.count,
                candidatePairCount: report.diagnostics.candidatePairCount,
                contactCount: report.diagnostics.contactPairCount,
                didOverflow: false
            ),
            appliedCommandCount: report.appliedCommandCount,
            hasNonFiniteState: containsNonFiniteState(snapshot)
        )
    }

    private func containsNonFiniteState(_ snapshot: MetalWorldSnapshot) -> Bool {
        snapshot.particles.contains {
            !$0.position.x.isFinite || !$0.position.y.isFinite ||
                !$0.previousPosition.x.isFinite || !$0.previousPosition.y.isFinite
        }
    }
}
