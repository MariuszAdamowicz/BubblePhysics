import BubblePhysicsReference
import SwiftUI

@MainActor final class ReferenceBenchmarkViewModel: ObservableObject {
    @Published var bubbleCount = 300
    @Published var broadPhase = ReferenceBroadPhaseSelection.sweepAndPrune
    @Published var progress = 0.0
    @Published var report: ReferenceBenchmarkReport?
    @Published var errorMessage: String?
    @Published var isRunning = false

    private var task: Task<Void, Never>?
    private var lastPublished = ContinuousClock.now

    func start() {
        stop()
        isRunning = true
        progress = 0
        report = nil
        errorMessage = nil
        let scenario = ReferenceBenchmarkScenario.filled(count: bubbleCount, broadPhase: broadPhase)
        task = Task {
            do {
                let result = try await ReferenceBenchmarkRunner.measureAsync(
                    scenario: scenario,
                    warmupSteps: 30,
                    measuredSteps: 300
                ) { [weak self] completed, total in
                    await self?.publishProgress(completed: completed, total: total)
                }
                guard !Task.isCancelled else { return }
                report = result
                progress = 1
                isRunning = false
            } catch is CancellationError {
                isRunning = false
            } catch {
                errorMessage = String(describing: error)
                isRunning = false
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        isRunning = false
    }

    private func publishProgress(completed: Int, total: Int) {
        let now = ContinuousClock.now
        guard completed == total || lastPublished.duration(to: now) >= .milliseconds(250) else { return }
        lastPublished = now
        progress = total == 0 ? 1 : Double(completed) / Double(total)
    }
}

struct ReferenceBenchmarkView: View {
    @StateObject private var model = ReferenceBenchmarkViewModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Reference CPU").font(.title2.bold())
                Picker("Bańki", selection: $model.bubbleCount) {
                    Text("40").tag(40)
                    Text("300").tag(300)
                    Text("1000").tag(1_000)
                }.pickerStyle(.segmented).disabled(model.isRunning)
                Picker("Broad phase", selection: $model.broadPhase) {
                    Text("Sweep").tag(ReferenceBroadPhaseSelection.sweepAndPrune)
                    Text("AABB tree").tag(ReferenceBroadPhaseSelection.aabbTree)
                }.pickerStyle(.segmented).disabled(model.isRunning)
                ProgressView(value: model.progress)
                HStack {
                    Button(model.isRunning ? "Uruchomiony" : "Start") { model.start() }
                        .buttonStyle(.borderedProminent).disabled(model.isRunning)
                    Button("Stop") { model.stop() }.disabled(!model.isRunning)
                }
                if let report = model.report { reportView(report) }
                if let error = model.errorMessage { Text(error).foregroundStyle(.red) }
            }
            .padding(.horizontal, 18)
            .padding(.top, 90)
            .padding(.bottom, 30)
        }
        .background(Color(.systemBackground))
        .onDisappear { model.stop() }
    }

    @ViewBuilder private func reportView(_ report: ReferenceBenchmarkReport) -> some View {
        Group {
            Text(String(format: "klatka p50 %.2f · p95 %.2f ms", report.frame.p50Milliseconds, report.frame.p95Milliseconds))
            Text(String(format: "predykcja %.2f · broad %.2f · kontakty %.2f · solver %.2f ms (p95)", report.prediction.p95Milliseconds, report.broadPhaseTiming.p95Milliseconds, report.contacts.p95Milliseconds, report.solver.p95Milliseconds))
            Text("kandydaci \(report.maximumCandidatePairs) · kontakty \(report.maximumGeneratedContacts)/\(report.maximumPersistentContacts) · TOI \(report.maximumTOITests)")
            Text(String(format: "penetracja %.4f · iteracje %d · limity %d · korekty strony %d", report.maximumPenetration, report.maximumSolverIterations, report.solverIterationLimitCount, report.sideCorrectionCount))
            Text("non-finite \(report.hasNonFiniteState ? "tak" : "nie")")
        }
        .font(.caption.monospacedDigit())
        .textSelection(.enabled)
    }
}
