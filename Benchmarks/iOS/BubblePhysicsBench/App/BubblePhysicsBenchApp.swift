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
    @State private var result = "Gotowy: 300 baniek, 300 kroków."
    @State private var running = false

    var body: some View {
        VStack(spacing: 20) {
            Text("BubblePhysics Bench")
                .font(.largeTitle.bold())
            Text(result)
                .multilineTextAlignment(.center)
            Button(running ? "Pomiar trwa" : "Uruchom 300 kroków") {
                running = true
                Task.detached {
                    let report = BenchmarkReport.measure(steps: 300)
                    await MainActor.run {
                        result = String(format: "p50 %.2f ms · p95 %.2f ms · kandydaci %d", report.p50Milliseconds, report.p95Milliseconds, report.finalDiagnostics.candidatePairCount)
                        running = false
                    }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)
        }
        .padding()
    }
}
