import BubblePhysics
import SwiftUI

@main
struct BubblePhysicsBenchApp: App {
    var body: some Scene {
        WindowGroup {
            BenchmarkView()
        }
    }
}

private struct BenchmarkView: View {
    @State private var result = "Gotowy: 300 baniek. Zacznij od szybkiego pomiaru jednego kroku."
    @State private var running = false

    var body: some View {
        VStack(spacing: 20) {
            Text("BubblePhysics Bench")
                .font(.largeTitle.bold())
            Text(result)
                .multilineTextAlignment(.center)
            Button("Szybki pomiar: 1 krok") {
                run(steps: 1)
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)

            Button("Pełny pomiar: 300 kroków") {
                run(steps: 300)
            }
            .disabled(running)
        }
        .padding()
    }

    private func run(steps: Int) {
        running = true
        result = "Przygotowanie sceny z 300 bańkami…"
        Task.detached {
            let report = BenchmarkReport.measure(steps: steps) { progress in
                Task { @MainActor in
                    result = "Pomiar: krok \(progress.completedSteps) / \(progress.totalSteps)"
                }
            }
            await MainActor.run {
                result = String(format: "p50 %.2f ms · p95 %.2f ms · kandydaci %d", report.p50Milliseconds, report.p95Milliseconds, report.finalDiagnostics.candidatePairCount)
                running = false
            }
        }
    }
}
