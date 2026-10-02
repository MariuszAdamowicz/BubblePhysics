import Foundation

public enum ReferenceBenchmarkRunner {
    public static func measure(
        scenario: ReferenceBenchmarkScenario,
        warmupSteps: Int,
        measuredSteps: Int
    ) throws -> ReferenceBenchmarkReport {
        var world = try scenario.makeWorld()
        for _ in 0..<max(0, warmupSteps) { _ = world.step() }

        let clock = ContinuousClock()
        var frames: [Double] = []
        var predictions: [Double] = []
        var broadPhases: [Double] = []
        var contactTimes: [Double] = []
        var solvers: [Double] = []
        var reports: [ReferenceWorldStepReport] = []

        for _ in 0..<max(0, measuredSteps) {
            let start = clock.now
            let report = world.step()
            let elapsed = start.duration(to: clock.now)
            frames.append(milliseconds(elapsed))
            predictions.append(report.predictionMilliseconds)
            broadPhases.append(report.broadPhaseMilliseconds)
            contactTimes.append(report.contactMilliseconds)
            solvers.append(report.solverMilliseconds)
            reports.append(report)
        }

        return ReferenceBenchmarkReport(
            scenarioName: scenario.name,
            broadPhase: scenario.broadPhase,
            warmupSteps: max(0, warmupSteps),
            measuredSteps: max(0, measuredSteps),
            frame: summary(frames),
            prediction: summary(predictions),
            broadPhaseTiming: summary(broadPhases),
            contacts: summary(contactTimes),
            solver: summary(solvers),
            maximumCandidatePairs: reports.map(\.candidatePairCount).max() ?? 0,
            maximumGeneratedContacts: reports.map(\.generatedContactCount).max() ?? 0,
            maximumPersistentContacts: reports.map(\.persistentContactCount).max() ?? 0,
            maximumSolverIterations: reports.map(\.solver.iterations).max() ?? 0,
            maximumTOITests: reports.map(\.toiTestCount).max() ?? 0,
            maximumPenetration: reports.map(\.solver.maximumPenetration).max() ?? 0,
            sideCorrectionCount: reports.reduce(0) { $0 + $1.sideCorrectionCount },
            solverIterationLimitCount: reports.reduce(0) { $0 + ($1.solver.didReachIterationLimit ? 1 : 0) },
            hasNonFiniteState: reports.contains(where: \.hasNonFiniteState)
        )
    }

    private static func summary(_ values: [Double]) -> ReferenceTimingSummary {
        let ordered = values.filter(\.isFinite).sorted()
        guard !ordered.isEmpty else { return .init(p50Milliseconds: 0, p95Milliseconds: 0) }
        return .init(
            p50Milliseconds: percentile(ordered, fraction: 0.50),
            p95Milliseconds: percentile(ordered, fraction: 0.95)
        )
    }

    private static func percentile(_ ordered: [Double], fraction: Double) -> Double {
        let index = max(0, min(ordered.count - 1, Int(ceil(Double(ordered.count) * fraction)) - 1))
        return ordered[index]
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }
}
