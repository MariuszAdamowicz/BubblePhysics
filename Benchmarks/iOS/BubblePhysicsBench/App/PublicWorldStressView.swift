import BubblePhysicsMetalRender
import Metal
import SwiftUI
import UIKit

/// Ręcznie uruchamiany pomiar fizycznego urządzenia; wynik można skopiować do raportu.
struct PublicWorldStressView: View {
    private typealias Scene = PublicWorldStressBenchmark.Scene

    private let scenes: [(title: String, scene: Scene)] = [
        ("stress-300", .stress(bubbleCount: 300)),
        ("mixed", .mixed),
        ("decals", .decals),
        ("acceptance", .acceptance)
    ]

    @State private var selectedIndex = 3
    @State private var task: Task<Void, Never>?
    @State private var completed = 0
    @State private var totalFrames = 660
    @State private var report: String?
    @State private var error: String?
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Publiczny benchmark świata").font(.title2.bold())
                Text("BubbleWorld + bezpośredni renderer, ten sam command buffer; limit 4, 30 klatek rozgrzewki i 300 mierzonych, potem druga seria tych samych klatek bez renderu (pomiar fizyki). Render poza ekranem w natywnej rozdzielczości ekranu. Wynik akceptacyjny (scena acceptance) wymaga fizycznego iPhone X.")
                Picker("Scena", selection: $selectedIndex) {
                    ForEach(scenes.indices, id: \.self) { Text(scenes[$0].title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(isRunning)
                ProgressView(value: Double(completed), total: Double(totalFrames))
                if isRunning {
                    Text("Pomiar trwa: \(completed) / \(totalFrames)")
                        .font(.headline)
                }
                HStack {
                    Button("Start") { start() }.disabled(isRunning)
                    Button("Stop") { task?.cancel() }.disabled(!isRunning)
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
        let scene = scenes[selectedIndex].scene
        completed = 0; totalFrames = 660; report = nil; error = nil
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            // Pozwala SwiftUI najpierw pokazać aktywny stan przycisku i postęp.
            await Task.yield()
            do {
                // Rozmiar celu to piksele ekranu, nie punkty: pomiar obejmuje koszt wypełnienia pełnej rozdzielczości.
                let result = try await PublicWorldStressBenchmark.measure(
                    device: device, scene: scene, renderSize: UIScreen.main.nativeBounds.size) { done, total in
                    completed = done
                    totalFrames = total
                }
                report = result.text
            } catch is CancellationError {
                error = "Pomiar przerwany"
            } catch {
                self.error = String(describing: error)
            }
            UIApplication.shared.isIdleTimerDisabled = false
            isRunning = false
            task = nil
        }
    }
}
