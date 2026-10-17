import BubblePhysics
import BubblePhysicsMetalRender
import MetalKit
import SwiftUI

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
        view.enableSetNeedsDisplay = false
        context.coordinator.start(view: view)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {}

    static func dismantleUIView(_ uiView: MTKView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject {
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
        private var loop: Task<Void, Never>?
        private var lastPresentedStep: UInt64 = 0

        func start(view: MTKView) {
            loop = Task { [weak view] in
                while !Task.isCancelled {
                    if let view, let drawable = view.currentDrawable,
                       let pass = view.currentRenderPassDescriptor,
                       let command = queue.makeCommandBuffer() {
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
                    }
                    try? await Task.sleep(nanoseconds: 16_666_667)
                }
            }
        }

        func stop() { loop?.cancel(); loop = nil }
    }
}
