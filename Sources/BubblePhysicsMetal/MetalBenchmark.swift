import Foundation
import BubblePhysics

public struct MetalBenchmarkReport: Equatable, Sendable {
    public let stepCount: Int
    public let p50Milliseconds: Double
    public let p95Milliseconds: Double
    public let shapeMilliseconds: Double
    public let contactMilliseconds: Double
    public let interactionMilliseconds: Double
    public let particleCount: Int
    public let candidatePairCount: Int
    public let contactCount: Int
    public let didOverflow: Bool
    public let hasNonFiniteState: Bool

    public static func measure(
        scenario: BenchmarkScenario = .iPhoneX,
        steps: Int,
        onProgress: (@Sendable (BenchmarkProgress) -> Void)? = nil
    ) async throws -> MetalBenchmarkReport {
        precondition(steps > 0)
        guard let solver = MetalBubbleSolver() else { throw MetalSolverError.metalUnavailable }
        var snapshot = MetalWorldSnapshot(world: scenario.makeWorld())
        var samples: [Double] = []
        var shapeTotal = 0.0, contactTotal = 0.0, interactionTotal = 0.0
        var candidates = 0
        for index in 0..<steps {
            let stepStart = Date()
            let shapeStart = Date()
            let shape = try await solver.solveShape(snapshot: snapshot, gravity: .zero, bounds: scenario.bounds, configuration: scenario.configuration)
            shapeTotal += Date().timeIntervalSince(shapeStart) * 1_000
            snapshot = snapshot.replacingParticles(shape.particles)
            let contactStart = Date()
            let contacts = try await solver.solveContacts(snapshot: snapshot, configuration: scenario.configuration)
            contactTotal += Date().timeIntervalSince(contactStart) * 1_000
            candidates = contacts.candidatePairCount
            snapshot = snapshot.replacingParticles(contacts.particles)
            if !snapshot.polygons.isEmpty || !snapshot.grabs.isEmpty {
                let interactionStart = Date()
                let interactions = try await solver.solveInteractions(snapshot: snapshot, configuration: scenario.configuration)
                interactionTotal += Date().timeIntervalSince(interactionStart) * 1_000
                snapshot = snapshot.replacingParticles(interactions.particles)
            }
            samples.append(Date().timeIntervalSince(stepStart) * 1_000)
            onProgress?(BenchmarkProgress(completedSteps: index + 1, totalSteps: steps))
        }
        let sorted = samples.sorted()
        let divisor = Double(steps)
        return MetalBenchmarkReport(
            stepCount: steps,
            p50Milliseconds: sorted[sorted.count / 2],
            p95Milliseconds: sorted[min(sorted.count - 1, Int(Double(sorted.count - 1) * 0.95))],
            shapeMilliseconds: shapeTotal / divisor,
            contactMilliseconds: contactTotal / divisor,
            interactionMilliseconds: interactionTotal / divisor,
            particleCount: snapshot.particles.count,
            candidatePairCount: candidates,
            contactCount: candidates,
            didOverflow: false,
            hasNonFiniteState: snapshot.particles.contains { !$0.position.x.isFinite || !$0.position.y.isFinite }
        )
    }
}
