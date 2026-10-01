import BubblePhysics
import BubblePhysicsMetal
import MetalKit
import SwiftUI

@main struct BubblePhysicsBenchApp: App { var body: some Scene { WindowGroup { PrototypeScreen() } } }

@MainActor final class PrototypeViewModel: ObservableObject {
    @Published var scene: PrototypeSceneSize = .inspection
    @Published var isPaused = false
    @Published var diagnostics = false
    @Published var trianglePaused = false
    @Published var telemetry = FrameTelemetrySnapshot(fps: 0, p50Milliseconds: 0, p95Milliseconds: 0, sampleCount: 0, failure: nil)
    @Published var errorMessage: String?
    @Published var resetGeneration = 0
}

private struct PrototypeScreen: View {
    @StateObject private var model = PrototypeViewModel()
    var body: some View {
        ZStack(alignment: .top) {
            MetalPrototypeView(model: model).ignoresSafeArea()
            VStack(spacing: 8) {
                HStack { Picker("Scena", selection: $model.scene) { Text("40").tag(PrototypeSceneSize.inspection); Text("300").tag(PrototypeSceneSize.stress) }.pickerStyle(.segmented); Button(model.isPaused ? "Wznów" : "Pauza") { model.isPaused.toggle() }; Button("Reset") { model.resetGeneration += 1; model.errorMessage = nil } }
                HStack { Toggle("Punkty", isOn: $model.diagnostics); Toggle("Pauza △", isOn: $model.trianglePaused) }
                Text(String(format: "%.0f FPS · p50 %.2f · p95 %.2f ms", model.telemetry.fps, model.telemetry.p50Milliseconds, model.telemetry.p95Milliseconds)).font(.caption.monospacedDigit())
                if let error = model.errorMessage { Text(error).foregroundStyle(.red).font(.caption) }
            }.padding(10).background(.ultraThinMaterial).clipShape(RoundedRectangle(cornerRadius: 14)).padding()
        }
    }
}

private struct MetalPrototypeView: UIViewRepresentable {
    @ObservedObject var model: PrototypeViewModel
    func makeCoordinator() -> MetalPrototypeCoordinator { .init(model: model) }
    func makeUIView(context: Context) -> TouchMetalView { let view = TouchMetalView(frame: .zero, device: MTLCreateSystemDefaultDevice()); view.colorPixelFormat = .bgra8Unorm; view.preferredFramesPerSecond = 60; view.delegate = context.coordinator; context.coordinator.attach(view); return view }
    func updateUIView(_ view: TouchMetalView, context: Context) { context.coordinator.synchronize(model) }
}

private final class TouchMetalView: MTKView {
    var touch: ((UITouch.Phase, CGPoint, TimeInterval) -> Void)?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches) }
    private func forward(_ touches: Set<UITouch>) { if let value = touches.first { touch?(value.phase, value.location(in: self), value.timestamp) } }
}

@MainActor private final class MetalPrototypeCoordinator: NSObject, MTKViewDelegate {
    private weak var model: PrototypeViewModel?
    private var session: MetalSimulationSession?; private var renderer: MetalBubbleRenderer?; private var queue: MTLCommandQueue?
    private var scene: PrototypeSceneSize = .inspection; private var generation = -1; private var start = CACurrentMediaTime()
    private var telemetry = FrameTelemetry(); private var lastResources: MetalFrameResources?; private var lastPublish = 0.0
    init(model: PrototypeViewModel) { self.model = model }
    func attach(_ view: TouchMetalView) { guard let device = view.device else { return }; queue = device.makeCommandQueue(); renderer = try? .init(device: device, pixelFormat: view.colorPixelFormat, worldBounds: PrototypeSceneFactory.bounds); view.touch = { [weak self, weak view] phase, point, time in self?.handle(phase, point, time, view?.bounds.size ?? .zero) }; rebuild(device) }
    func synchronize(_ model: PrototypeViewModel) { if scene != model.scene || generation != model.resetGeneration, let device = queue?.device { scene = model.scene; generation = model.resetGeneration; rebuild(device) } }
    private func rebuild(_ device: MTLDevice) { do { let snapshot = MetalWorldSnapshot(world: try PrototypeSceneFactory.make(scene)); session = try .init(snapshot: snapshot, device: device); renderer?.rebuildSceneResources(ranges: snapshot.bubbleRanges, labels: snapshot.bubbleRanges.map { String($0.id) }); telemetry.reset(); start = CACurrentMediaTime() } catch { Task { @MainActor in self.model?.errorMessage = "Błąd Metal: \(error)" } } }
    func draw(in view: MTKView) {
        guard let model, !model.isPaused, model.errorMessage == nil, let session, let renderer, let queue, let command = queue.makeCommandBuffer(), let drawable = view.currentDrawable else { return }
        do { let triangle = KinematicTriangleMotion.default.sample(time: CACurrentMediaTime() - start, isPaused: model.trianglePaused); let frame = try session.encodeFrame(input: .init(gravity: .zero, bounds: PrototypeSceneFactory.bounds, triangleState: triangle), commandBuffer: command); lastResources = frame; _ = try renderer.encode(frame: frame, diagnostics: model.diagnostics, renderPass: view.currentRenderPassDescriptor, drawableSize: view.drawableSize, commandBuffer: command); command.present(drawable); let began = CACurrentMediaTime(); command.addCompletedHandler { [weak self] _ in Task { @MainActor in self?.completed(began) } }; command.commit() } catch { model.errorMessage = "Błąd sesji Metal: \(error)" }
    }
    private func completed(_ began: Double) { if case let .failed(failure) = session?.status { telemetry.fail(failure); model?.errorMessage = "Sesja Metal zatrzymana: \(failure)"; return }; telemetry.record(milliseconds: (CACurrentMediaTime() - began) * 1000); let now = CACurrentMediaTime(); if now - lastPublish > 0.25 { lastPublish = now; model?.telemetry = telemetry.snapshot } }
    private func handle(_ phase: UITouch.Phase, _ point: CGPoint, _ timestamp: TimeInterval, _ size: CGSize) { guard size.width > 0, size.height > 0, let session, let resources = lastResources else { return }; let viewport = MetalWorldViewport(worldBounds: PrototypeSceneFactory.bounds, drawableSize: size); let world = viewport.viewToWorld(SIMD2(Float(point.x), Float(point.y))); switch phase { case .began: Task { _ = try? await session.beginGrab(at: world, resources: resources, timestamp: timestamp) }; case .moved: session.moveGrab(to: world, timestamp: timestamp); default: session.endGrab() } }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
