import BubblePhysics
import BubblePhysicsMetalRender
import MetalKit
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

/// Produkcyjna demonstracja publicznego API: kontury pozostają na GPU.
struct PublicMetalPreviewView: View {
    var body: some View {
        PublicMetalSurface()
            .ignoresSafeArea()
            .navigationTitle("Publiczny renderer Metal")
            .navigationBarTitleDisplayMode(.inline)
    }
}

private struct PublicMetalSurface: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = context.coordinator.device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0.025, 0.04, 0.07, 1)
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        context.coordinator.start(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.stop()
        uiView.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()!
        private lazy var queue = device.makeCommandQueue()!
        private lazy var renderer = try! BubblePhysicsMetalRender(device: device)
        private lazy var world: BubbleWorld = {
            let region = try! WorldRectangle(min: [0, 0], max: [375, 700])
            let world = try! BubbleWorld(configuration: WorldConfiguration(
                simulationRegion: region, fixedTimeStep: 1.0 / 60), device: device)
            let material = PhysicsMaterialID(rawValue: 1)
            let style = RenderStyleID(rawValue: 1)
            var transaction = WorldTransaction()
                .updatePhysicsMaterial(material, material: try! PhysicsMaterial(kind: .bubble))
                .updateRenderStyle(style, style: try! RenderStyle())
            for row in 0..<20 {
                for column in 0..<15 {
                    let id = ObjectID(rawValue: UInt64(row * 15 + column + 1))
                    let position = WorldPoint(Float(52 + column * 19), Float(120 + row * 22))
                    transaction = transaction.add(.bubble(try! BubbleDescriptor(
                        id: id, position: position, targetRadius: 7,
                        physicsMaterialID: material, renderStyleID: style)))
                }
            }
            world.submit(transaction)
            return world
        }()
        private var inFlight: Task<Void, Never>?
        private var lastPresentedStep: UInt64 = 0
        private var stopped = false

        func start(view: MTKView) {
            stopped = false
            view.delegate = self
            view.setNeedsDisplay()
        }

        func draw(in view: MTKView) {
            guard !stopped, inFlight == nil else { return }
            guard let drawable = view.currentDrawable,
                  let pass = view.currentRenderPassDescriptor,
                  let command = queue.makeCommandBuffer() else {
                requestNextDraw(view)
                return
            }
            inFlight = Task { [weak view] in
                let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
                    try self.renderer.encode(world: self.world,
                        viewport: Viewport(center: [187.5, 350], size: [375, 700]),
                        commandBuffer: command, renderPassDescriptor: pass)
                }
                if frame.stepIndex > lastPresentedStep,
                   world.diagnostics.lastAdvanceIssue == nil {
                    drawable.present()
                    lastPresentedStep = frame.stepIndex
                }
                inFlight = nil
                if let view, !Task.isCancelled, !stopped { requestNextDraw(view) }
            }
        }

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        private func requestNextDraw(_ view: MTKView) {
            Task { [weak view] in
                try? await Task.sleep(nanoseconds: 16_666_667)
                if !Task.isCancelled, !stopped { view?.setNeedsDisplay() }
            }
        }

        func stop() { stopped = true; inFlight?.cancel(); inFlight = nil }
    }
}
