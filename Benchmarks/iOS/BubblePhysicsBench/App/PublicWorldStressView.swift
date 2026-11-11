import BubblePhysicsMetalRender
import BubblePhysicsMetalRenderBenchmark
import Metal
import SwiftUI
import UIKit

/// Ręcznie uruchamiany pomiar fizycznego urządzenia; wynik można skopiować do raportu.
struct PublicWorldStressView: View {
    private typealias Scene = PublicWorldStressBenchmark.Scene

    /// `scene == nil` to tryb pojemności: poziomy 100–400 baniek sceny akceptacyjnej w jednym uruchomieniu.
    private let scenes: [(title: String, scene: Scene?)] = [
        ("stress-300", .stress(bubbleCount: 300)),
        ("mixed", .mixed),
        ("decals", .decals),
        ("acceptance", .acceptance),
        ("capacity", nil)
    ]

    @State private var selectedIndex = 3
    @State private var task: Task<Void, Never>?
    @State private var completed = 0
    @State private var totalFrames = 1
    @State private var progressText = ""
    @State private var report: String?
    @State private var error: String?
    @State private var isRunning = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Publiczny benchmark świata").font(.title2.bold())
                Text("BubbleWorld + bezpośredni renderer, ten sam command buffer; limit 4, 30 klatek rozgrzewki i 300 mierzonych, potem druga seria tych samych klatek bez renderu (pomiar fizyki). Render poza ekranem w natywnej rozdzielczości ekranu. Wynik akceptacyjny (scena acceptance) wymaga fizycznego iPhone X. Tryb capacity przechodzi poziomy 100–400 baniek co 50: przed każdym czeka, aż stan termiczny wróci do nominal (najdłużej 10 minut), i podaje pojemność przy 60 FPS.")
                Picker("Scena", selection: $selectedIndex) {
                    ForEach(scenes.indices, id: \.self) { Text(scenes[$0].title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(isRunning)
                ProgressView(value: Double(completed), total: Double(totalFrames))
                if isRunning {
                    Text(progressText.isEmpty ? "Pomiar trwa: \(completed) / \(totalFrames)" : progressText)
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
        completed = 0; totalFrames = 1; progressText = ""; report = nil; error = nil
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            // Pozwala SwiftUI najpierw pokazać aktywny stan przycisku i postęp.
            await Task.yield()
            do {
                if let scene {
                    // Rozmiar celu to piksele ekranu, nie punkty: pomiar obejmuje koszt wypełnienia pełnej rozdzielczości.
                    let result = try await PublicWorldStressBenchmark.measure(
                        device: device, scene: scene, renderSize: UIScreen.main.nativeBounds.size) { done, total in
                        completed = done
                        totalFrames = total
                    }
                    report = result.text
                } else {
                    // Tryb pojemności ma własne cele renderu poziomów (1125 × 920…3252 px), więc nie bierze rozmiaru ekranu.
                    let result = try await PublicWorldStressBenchmark.measureCapacity(device: device) { update in
                        show(update)
                    }
                    report = result.text
                }
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

    /// Poziom, czekanie na schłodzenie i postęp klatek z wywołania zwrotnego `measureCapacity`.
    private func show(_ update: PublicWorldCapacityProgress) {
        let level = "Poziom \(update.bubbleCount) baniek (\(update.levelIndex + 1) z \(update.levelCount))"
        switch update.phase {
        case .cooldown(let seconds, let state):
            progressText = "\(level): czekanie na schłodzenie, \(Int(seconds)) s, stan \(Self.name(of: state))"
            completed = update.levelIndex
            totalFrames = update.levelCount
        case .measuring(let done, let total):
            progressText = "\(level): klatka \(done) z \(total)"
            completed = update.levelIndex * total + done
            totalFrames = update.levelCount * total
        }
    }

    private static func name(of state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "nieznany"
        }
    }
}
