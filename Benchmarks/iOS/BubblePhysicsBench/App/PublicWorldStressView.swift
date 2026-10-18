import BubblePhysicsMetalRender
import Metal
import SwiftUI
import UIKit

/// Ręcznie uruchamiany pomiar fizycznego urządzenia; wynik można skopiować do raportu.
struct PublicWorldStressView: View {
    @State private var task: Task<Void, Never>?
    @State private var completed = 0
    @State private var report: String?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Publiczny stress-300").font(.title2.bold())
                Text("BubbleWorld + bezpośredni renderer, ten sam command buffer; limit 4, 30 klatek rozgrzewki i 300 mierzonych. Wynik akceptacyjny wymaga fizycznego iPhone X.")
                ProgressView(value: Double(completed), total: 330)
                HStack {
                    Button("Start") { start() }.disabled(task != nil)
                    Button("Stop") { task?.cancel() }.disabled(task == nil)
                }
                if let report {
                    Button("Kopiuj raport") { UIPasteboard.general.string = report }
                    Text(report).font(.caption.monospaced()).textSelection(.enabled)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }.padding()
        }
        .onDisappear { task?.cancel() }
    }

    private func start() {
        guard let device = MTLCreateSystemDefaultDevice() else { error = "Metal niedostępny"; return }
        completed = 0; report = nil; error = nil
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            do {
                let result = try await PublicWorldStressBenchmark.measure(device: device) { done, _ in
                    completed = done
                }
                report = result.text
            } catch is CancellationError {
                error = "Pomiar przerwany"
            } catch {
                self.error = String(describing: error)
            }
            UIApplication.shared.isIdleTimerDisabled = false
            task = nil
        }
    }
}
