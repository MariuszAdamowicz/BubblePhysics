import BubblePhysicsMetalRender
import Metal
import MetalKit
import SwiftUI
import UIKit

/// Ręcznie uruchamiany pomiar fizycznego urządzenia; wynik można skopiować do raportu.
struct PublicWorldStressView: View {
    @State private var task: Task<Void, Never>?
    @State private var completed = 0
    @State private var report: String?
    @State private var error: String?
    @State private var isRunning = false
    @StateObject private var drawableSource = StressDrawableSource()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Benchmark rundy engine-owned").font(.title2.bold())
                Text("Semantyczny spawn, drag, merge i gęsta arena; limit 4, 120 klatek rozgrzewki i 300 mierzonych na scenariusz. Wynik akceptacyjny wymaga Release na fizycznym iPhonie X.")
                ProgressView(value: Double(completed), total: 1680)
                if isRunning {
                    Text("Pomiar trwa: \(completed) / 1680")
                        .font(.headline)
                }
                HStack {
                    Button("Start") { start() }.disabled(isRunning)
                    Button("Stop") { task?.cancel() }.disabled(!isRunning)
                }
                StressDrawableView(source: drawableSource)
                    .frame(maxWidth: .infinity)
                    .aspectRatio(375.0 / 700.0, contentMode: .fit)
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
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
        task = Task {
            // Pozwala SwiftUI najpierw pokazać aktywny stan przycisku i postęp.
            await Task.yield()
            do {
                let result = try await PublicWorldStressBenchmark.measure(device: device, drawableProvider: {
                    try await drawableSource.nextDrawable()
                }) { done, _ in
                    completed = done
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

@MainActor
private final class StressDrawableSource: ObservableObject {
    weak var view: MTKView?
    private var pending: CheckedContinuation<CAMetalDrawable, Never>?

    func nextDrawable() async throws -> CAMetalDrawable {
        await withCheckedContinuation { continuation in
            pending = continuation
            view?.setNeedsDisplay()
        }
    }

    func didDraw(_ view: MTKView) {
        guard let pending else { return }
        guard let drawable = view.currentDrawable else { return }
        self.pending = nil
        pending.resume(returning: drawable)
    }
}

private struct StressDrawableView: UIViewRepresentable {
    @ObservedObject var source: StressDrawableSource

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.framebufferOnly = true
        view.colorPixelFormat = .bgra8Unorm
        view.delegate = context.coordinator
        source.view = view
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        source.view = view
    }

    func makeCoordinator() -> Coordinator { Coordinator(source: source) }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        private let source: StressDrawableSource
        init(source: StressDrawableSource) { self.source = source }
        func draw(in view: MTKView) { source.didDraw(view) }
        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    }
}
