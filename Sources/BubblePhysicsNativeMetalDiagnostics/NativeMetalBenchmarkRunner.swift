import Foundation
import BubblePhysicsReference

/// Reuses the reference scenes, matrix and full-frame measurement boundary.
@MainActor
public enum NativeMetalBenchmarkRunner {
    public static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in }
    ) async throws -> ReferenceBenchmarkMatrixReport {
        try await measure(configuration: configuration, progress: progress, makeRunner: { limit in
            NativeMetalWorldRunner(configuration: .init(solverIterationCount: limit))
                ?? NativeMetalWorldRunner(executor: nil, configuration: .init(solverIterationCount: limit))
        })
    }

    static func measure(
        configuration: ReferenceBenchmarkMatrixConfiguration,
        progress: @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void = { _ in },
        makeRunner: @escaping @MainActor (Int) throws -> NativeMetalWorldRunner
    ) async throws -> ReferenceBenchmarkMatrixReport {
        guard configuration.backend == .nativeMetal else { throw ReferenceBenchmarkError.backendRequiresFrameExecutor }
        return try await ReferenceBenchmarkMatrixRunner.measure(configuration: configuration, progress: progress,
            run: { scenario, warmup, measured, localProgress in
                let runner = try await makeRunner(scenario.newtonIterationLimit)
                let sequence = await NativePublishedSequenceHash()
                var report = try await ReferenceBenchmarkRunner.measureAsync(scenario: scenario,
                    warmupSteps: warmup, measuredSteps: measured, backend: .nativeMetal,
                    frameExecutor: { world, scenario, step in
                        let frame = await runner.benchmarkFrame(world: &world, scenario: scenario, step: step)
                        sequence.observe(world: world, runner: runner)
                        return frame
                    }, progress: localProgress)
                report.nativeQuality = try await qualityEvidence(report: report, scenario: scenario,
                    originalHash: sequence.value, makeRunner: makeRunner)
                return report
            })
    }

    private static func qualityEvidence(report: ReferenceBenchmarkReport, scenario: ReferenceConvergenceScenario,
        originalHash: UInt64?, makeRunner: @escaping @MainActor (Int) throws -> NativeMetalWorldRunner
    ) async throws -> ReferenceBenchmarkNativeQualityReport {
        var evidence = ReferenceBenchmarkNativeQualityReport()
        guard report.measuredSteps > 0 else {
            evidence.violations = NativeMetalQualityEnvelope.evaluate(cpu: .init(report: report),
                gpu: .init(report: report)).map(\.rawValue)
            return evidence
        }
        // Same scene, seed, broad phase, warmup and explicit quality limit.
        // These batches are outside the measured GPU times and counters.
        let cpu = try await ReferenceBenchmarkRunner.measureAsync(scenario: scenario,
            warmupSteps: report.warmupSteps, measuredSteps: report.measuredSteps)
        evidence.cpuBaselineMeasuredFrames = cpu.measuredSteps
        evidence.cpuPenetrationP95 = cpu.penetration.p95
        evidence.cpuPenetrationMaximum = cpu.penetration.maximum
        if report.isGPUAcceptanceMeasurementEligible {
            evidence.publishedStateHash = originalHash
            let repeatedRunner = try makeRunner(scenario.newtonIterationLimit)
            let repeatedHash = NativePublishedSequenceHash()
            let repeated = try await ReferenceBenchmarkRunner.measureAsync(scenario: scenario,
                warmupSteps: report.warmupSteps, measuredSteps: report.measuredSteps, backend: .nativeMetal,
                frameExecutor: { world, scenario, step in
                    let frame = await repeatedRunner.benchmarkFrame(world: &world, scenario: scenario, step: step)
                    repeatedHash.observe(world: world, runner: repeatedRunner)
                    return frame
                })
            if repeated.isGPUAcceptanceMeasurementEligible {
                evidence.repeatMeasuredFrames = repeated.completedMetalSampleCount
                evidence.repeatedPublishedStateHash = repeatedHash.value
            }
            try await measureRest(into: &evidence, runner: makeRunner(scenario.newtonIterationLimit))
            try await measureRecovery(into: &evidence, runner: makeRunner(scenario.newtonIterationLimit))
        }
        var gpuReport = report
        gpuReport.nativeQuality = evidence
        evidence.violations = NativeMetalQualityEnvelope.evaluate(cpu: .init(report: cpu),
            gpu: .init(report: gpuReport)).map(\.rawValue)
        return evidence
    }

    private static func measureRest(into evidence: inout ReferenceBenchmarkNativeQualityReport,
                                    runner: NativeMetalWorldRunner) async throws {
        // Two initially touching bubbles receive opposite small impulses while
        // held between walls. No host resets during 120+30 continuous frames.
        var world = ReferenceWorld(configuration: .init(linearDamping: 1.5,
            maxContourSegmentLength: 0.1), broadPhase: BruteForceBroadPhase())
        for (id, x, velocity) in [(1, Float(-1), Float(0.1)), (2, Float(1), Float(-0.1))] {
            world.addBubble(try .init(id: .init(rawValue: id), center: .init(x: x, y: 0),
                velocity: .init(x: velocity, y: 0), mass: 1, targetRadius: 1))
        }
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: -2, y: -10), b: .init(x: -2, y: 10)))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 2, y: -10), b: .init(x: 2, y: 10)))
        var maximum: Double = 0
        for step in 0..<150 {
            try Task.checkCancellation()
            let previous = world.bubbles
            _ = await runner.step(world: &world, scenarioStep: step)
            guard isPublishedGPU(runner) else { return }
            if step < 120 { evidence.restSettleFrames += 1 }
            else {
                evidence.restMeasuredFrames += 1
                for (before, after) in zip(previous, world.bubbles) {
                    maximum = max(maximum, Double((after.center - before.center).length / after.targetRadius))
                }
            }
        }
        evidence.maximumRestDisplacementRadiusFraction = maximum
    }

    private static func measureRecovery(into evidence: inout ReferenceBenchmarkNativeQualityReport,
                                        runner: NativeMetalWorldRunner) async throws {
        var world = ReferenceWorld(configuration: .init(timeStep: 1 / 60, linearDamping: 0,
            angularDamping: 0, maxContourSegmentLength: 0.1), broadPhase: BruteForceBroadPhase())
        world.addBubble(try .init(id: .init(rawValue: 1), center: .init(x: -0.6, y: 0), mass: 1, targetRadius: 1))
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: -10), b: .init(x: 0, y: 10)))
        _ = await runner.step(world: &world, scenarioStep: 0)
        guard isPublishedGPU(runner), let loaded = radiusErrors(world: world, runner: runner) else { return }
        evidence.loadedContourMeanRadiusErrorFraction = loaded.mean
        // Kontur wynika teraz wyłącznie z zatwierdzonej geometrii. Twardy
        // solver może rozdzielić środek od ściany w tej samej klatce, więc brak
        // pozostałej deformacji jest wynikiem poprawnym i nie wymaga sztucznej
        // pamięci nacisku tylko po to, by testować jej wygaszanie.
        guard loaded.mean > 0.02 else {
            evidence.releasedContourMeanRadiusErrorFraction = 0
            evidence.contourOscillationGrows = false
            return
        }
        world.removeSegment(id: .init(rawValue: 1))
        var bubble = world.bubbles[0]
        bubble.velocity = .zero // Controlled release removes the loading impulse, once.
        world.updateBubble(bubble)
        var previousAmplitude = loaded.maximum
        var grows = false
        var finalMean: Double?
        for step in 1...30 {
            try Task.checkCancellation()
            _ = await runner.step(world: &world, scenarioStep: step)
            guard isPublishedGPU(runner), let errors = radiusErrors(world: world, runner: runner) else { return }
            if step == 1 && errors.maximum == 0 { return } // An instantaneous reset is missing recovery evidence.
            grows = grows || errors.maximum > previousAmplitude + 0.000001
            previousAmplitude = errors.maximum
            finalMean = errors.mean
            evidence.releasedContourFrames += 1
        }
        evidence.releasedContourMeanRadiusErrorFraction = finalMean
        evidence.contourOscillationGrows = grows
    }

    private static func isPublishedGPU(_ runner: NativeMetalWorldRunner) -> Bool {
        runner.telemetry.backend == .nativeMetal && runner.telemetry.fallbackReason == nil
            && !runner.telemetry.didEncounterNonFinite
    }

    private static func radiusErrors(world: ReferenceWorld, runner: NativeMetalWorldRunner)
        -> (mean: Double, maximum: Double)? {
        guard let bubble = world.bubbles.first, let points = runner.contours[bubble.id], !points.isEmpty else { return nil }
        let errors = points.map { Double(abs(($0 - bubble.center).length / bubble.targetRadius - 1)) }
        guard errors.allSatisfy(\.isFinite) else { return nil }
        return (errors.reduce(0, +) / Double(errors.count), errors.max()!)
    }
}

/// FNV-1a across every published frame, including warmup and contours. A single
/// fallback invalidates the whole sequence; CPU states never become GPU proof.
@MainActor
private final class NativePublishedSequenceHash {
    private var hash: UInt64 = 14695981039346656037
    private var valid = true
    private var frames = 0
    var value: UInt64? { valid && frames > 0 ? hash : nil }

    func observe(world: ReferenceWorld, runner: NativeMetalWorldRunner) {
        guard valid, runner.telemetry.backend == .nativeMetal, runner.telemetry.fallbackReason == nil,
              !runner.telemetry.didEncounterNonFinite else { valid = false; return }
        frames += 1
        append(UInt64(frames))
        for bubble in world.bubbles {
            append(UInt64(bitPattern: Int64(bubble.id.rawValue)))
            for value in [bubble.center.x, bubble.center.y, bubble.previousCenter.x, bubble.previousCenter.y,
                          bubble.velocity.x, bubble.velocity.y, bubble.rotation, bubble.angularVelocity] {
                append(UInt64(value.bitPattern))
            }
            guard let contour = runner.contours[bubble.id] else { valid = false; return }
            append(UInt64(contour.count))
            for point in contour { append(UInt64(point.x.bitPattern)); append(UInt64(point.y.bitPattern)) }
        }
        for contact in world.contacts.contacts {
            append(contact.id.rawValue)
            for value in [contact.normal.x, contact.normal.y, contact.pointQ.x, contact.pointQ.y,
                          contact.penetration, contact.accumulatedCompression] { append(UInt64(value.bitPattern)) }
        }
    }

    private func append(_ value: UInt64) { hash = (hash ^ value) &* 1099511628211 }
}

extension NativeMetalWorldRunner {
    fileprivate func benchmarkFrame(world: inout ReferenceWorld, scenario: ReferenceConvergenceScenario,
                                step: Int) async -> ReferenceBenchmarkFrameResult {
        let clock = ContinuousClock()
        let start = clock.now
        scenario.updatePolygon(in: &world, fromStep: step, toStep: step + 1)
        let simulationStart = clock.now
        var report = await self.step(world: &world, scenarioStep: step)
        report.hasNonFiniteState = report.hasNonFiniteState || telemetry.didEncounterNonFinite
        let simulationEnd = clock.now
        let geometry = world.bubbles.map { ($0, world.contour(for: $0.id)) }
        let contourEnd = clock.now
        let prepared = geometry.map { bubble, contour in
            ReferencePreparedBubble(id: bubble.id, center: bubble.center, rotation: bubble.rotation, contour: contour)
        }
        let end = clock.now
        let succeeded = telemetry.backend == .nativeMetal && telemetry.fallbackReason == nil
        if succeeded { report.solverMilliseconds = telemetry.gpuMilliseconds }
        let neutralProfile = ReferenceBenchmarkGPUFrameProfile(commandBufferCount: profile.commandBufferCount,
            encoderCount: profile.encoderCount, stageGPUMilliseconds: profile.stageGPUMilliseconds,
            hostEncodingMilliseconds: profile.hostEncodingMilliseconds,
            hostWaitingMilliseconds: profile.hostWaitingMilliseconds, hostReadbackMilliseconds: 0)
        return .init(worldReport: report,
            simulationMilliseconds: Self.milliseconds(simulationStart.duration(to: simulationEnd)),
            contourMilliseconds: Self.milliseconds(simulationEnd.duration(to: contourEnd)),
            renderPreparationMilliseconds: Self.milliseconds(contourEnd.duration(to: end)),
            fullFrameMilliseconds: Self.milliseconds(start.duration(to: end)),
            contourPointCount: prepared.reduce(0) { $0 + $1.contour.count }, preparedBubbles: prepared,
            backend: telemetry.backend, fallbackReason: telemetry.fallbackReason,
            gpuTelemetry: .init(completedCommandBuffersMilliseconds: succeeded ? telemetry.gpuMilliseconds : nil,
                contactCount: telemetry.contactCount, profile: succeeded ? neutralProfile : nil,
                native: succeeded ? .init(cacheHits: telemetry.cacheHitCount, cacheResets: telemetry.cacheResetCount,
                    solverIterations: telemetry.solverIterationCount, ccdCandidates: telemetry.ccdCandidateCount) : nil))
    }

    private static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
    }
}
