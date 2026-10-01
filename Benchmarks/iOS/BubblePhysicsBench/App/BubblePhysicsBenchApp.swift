import BubblePhysics
import BubblePhysicsMetal
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
    @State private var result = "Gotowy: pełna ścieżka Metal, 300 deformowalnych baniek."
    @State private var running = false

    var body: some View {
        VStack(spacing: 20) {
            Text("BubblePhysics Bench")
                .font(.largeTitle.bold())
            Text(result)
                .multilineTextAlignment(.center)
            Button("Metal: szybki pomiar (3 kroki)") {
                run(steps: 3)
            }
            .buttonStyle(.borderedProminent)
            .disabled(running)

            Button("Metal: pełny pomiar (300 kroków)") {
                run(steps: 300)
            }
            .disabled(running)
        }
        .padding()
    }

    private func run(steps: Int) {
        running = true
        result = "Przygotowanie sceny GPU z 300 bańkami…"
        Task.detached {
            do {
                let report = try await MetalBenchmarkReport.measure(steps: steps) { progress in
                    Task { @MainActor in
                        result = "Metal: krok \(progress.completedSteps) / \(progress.totalSteps)"
                    }
                }
                await MainActor.run {
                    result = String(
                        format: "METAL · p50 %.2f ms · p95 %.2f ms\nKształt %.2f · kontakty %.2f · interakcje %.2f ms\n↳ GPU fused (broad + sąsiedzi + solve) %.2f ms\nCząstki %d · kandydaci %d · kontakty %d\nOverflow %@ · non-finite %@",
                        report.p50Milliseconds,
                        report.p95Milliseconds,
                        report.shapeMilliseconds,
                        report.contactMilliseconds,
                        report.interactionMilliseconds,
                        report.contactSolveMilliseconds,
                        report.particleCount,
                        report.candidatePairCount,
                        report.contactCount,
                        report.didOverflow ? "TAK" : "nie",
                        report.hasNonFiniteState ? "TAK" : "nie"
                    )
                    running = false
                }
            } catch {
                await MainActor.run {
                    result = "Błąd benchmarku Metal: \(error)"
                    running = false
                }
            }
        }
    }
}
