import BubblePhysics
import BubblePhysicsMetalRender
import MetalKit
import SwiftUI
import UIKit

/// `MTKView` z jednym palcem: przekazuje fazę i punkt dotyku w punktach widoku.
final class TouchMTKView: MTKView {
    var onTouch: (@MainActor (UITouch.Phase, CGPoint) -> Void)?

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .began) }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .moved) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .ended) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { forward(touches, .cancelled) }

    private func forward(_ touches: Set<UITouch>, _ phase: UITouch.Phase) {
        guard let touch = touches.first else { return }
        onTouch?(phase, touch.location(in: self))
    }
}

/// Host świata: widok `MTKView`, pętla klatek i dotyk. Używa wyłącznie publicznego API.
struct MetalHostView: UIViewRepresentable {
    let kind: ShowcaseKind
    let isPaused: Bool

    func makeCoordinator() -> Coordinator { Coordinator(kind: kind) }

    func makeUIView(context: Context) -> TouchMTKView {
        let view = TouchMTKView(frame: .zero, device: context.coordinator.device)
        Coordinator.configure(view, clearColor: context.coordinator.clearColor)
        view.delegate = context.coordinator
        view.onTouch = { [weak coordinator = context.coordinator, weak view] phase, point in
            guard let view else { return }
            coordinator?.touch(phase, at: point, in: view)
        }
        return view
    }

    func updateUIView(_ view: TouchMTKView, context: Context) {
        context.coordinator.setPaused(isPaused)
    }

    @MainActor
    final class Coordinator: NSObject, MTKViewDelegate {
        let device = MTLCreateSystemDefaultDevice()
        private let scene: (any ShowcaseScene)?
        private let world: BubbleWorld?
        private let renderer: BubblePhysicsMetalRender?
        private let queue: MTLCommandQueue?
        private var isAdvancing = false
        private var lastTimestamp: CFTimeInterval?
        private var lastFrame: WorldFrame?
        private var lastViewport: Viewport?

        var clearColor: MTLClearColor { scene?.clearColor ?? MTLClearColorMake(0, 0, 0, 1) }

        init(kind: ShowcaseKind) {
            // Błąd tworzenia świata albo sceny zostawia widok pusty; przykład nie ma co z nim zrobić poza zapisem w logu.
            var built: (scene: any ShowcaseScene, world: BubbleWorld, renderer: BubblePhysicsMetalRender,
                        queue: MTLCommandQueue)?
            do {
                guard let device, let queue = device.makeCommandQueue() else {
                    throw BubblePhysicsMetalRenderError.deviceMismatch
                }
                let scene = try kind.makeScene()
                let world = try Self.makeWorld(for: scene, device: device)
                guard let assets = world.assets else { throw BubblePhysicsMetalRenderError.deviceMismatch }
                world.submit(try scene.prepare(assets: assets))
                built = (scene, world, try BubblePhysicsMetalRender(device: device, assets: assets), queue)
            } catch {
                print("Showcase: nie udało się utworzyć sceny: \(error)")
            }
            scene = built?.scene
            world = built?.world
            renderer = built?.renderer
            queue = built?.queue
            super.init()
        }

        // guide-region: pass-format
        /// Pass gry ma tylko kolor: bez bufora głębi i szablonu. Renderer bierze format koloru z deskryptora passu.
        static func configure(_ view: MTKView, clearColor: MTLClearColor) {
            view.colorPixelFormat = .bgra8Unorm
            view.depthStencilPixelFormat = .invalid
            view.framebufferOnly = true
            view.clearColor = clearColor
            view.preferredFramesPerSecond = UIScreen.main.maximumFramesPerSecond
        }
        // guide-region-end

        // guide-region: lifecycle
        /// Konfiguracja ma `automaticPause` (domyślnie włączone): w tle świat pauzuje sam i po powrocie odrzuca czas
        /// spędzony w tle. Pauza ręczna jest od niej niezależna.
        private static func makeWorld(for scene: any ShowcaseScene, device: MTLDevice) throws -> BubbleWorld {
            try BubbleWorld(configuration: scene.configuration, device: device)
        }

        func setPaused(_ paused: Bool) {
            if paused { world?.pause() } else { world?.resume() }
        }
        // guide-region-end

        func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

        // guide-region: mtkview-loop
        /// Jedna klatka `MTKView`: jeden bufor poleceń na fizykę i render. Drawable, deskryptor passu i bufor pobieramy
        /// synchronicznie, bo system podstawia je tylko na czas tego wywołania.
        func draw(in view: MTKView) {
            // Poprzedni `advance` jeszcze trwa: pobrany drawable po prostu nie zostaje użyty.
            guard !isAdvancing, let scene, let world, let renderer, let queue,
                  let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
                  let commandBuffer = queue.makeCommandBuffer(),
                  view.bounds.width > 0, view.bounds.height > 0,
                  let viewport = try? scene.viewport(aspect: Float(view.bounds.width / view.bounds.height))
            else { return }
            lastViewport = viewport
            let now = CACurrentMediaTime()
            let elapsed = now - (lastTimestamp ?? now)
            lastTimestamp = now
            isAdvancing = true
            Task { @MainActor in
                defer { isAdvancing = false }
                if let lastFrame { scene.update(frame: lastFrame, world: world) }
                lastFrame = await advanceAndPresent(world: world, seconds: elapsed, commandBuffer: commandBuffer,
                                                    drawable: drawable) {
                    try renderer.encode(world: world, viewport: viewport, commandBuffer: commandBuffer,
                                        renderPassDescriptor: pass)
                }
            }
        }
        // guide-region-end

        // guide-region: present-drawable
        /// Drawable prezentujemy tylko wtedy, gdy bufor z renderem został zatwierdzony i ukończony. W pauzie, w stanie
        /// „zawiódł” i po odrzuconej klatce `didRenderLastAdvance` jest fałszem, a bufor nie jest zatwierdzany.
        private func advanceAndPresent(world: BubbleWorld, seconds: TimeInterval, commandBuffer: MTLCommandBuffer,
                                       drawable: CAMetalDrawable, encode: @escaping () throws -> Void) async -> WorldFrame {
            let frame = await world.advance(by: seconds, commandBuffer: commandBuffer, encodeRender: encode)
            if world.diagnostics.didRenderLastAdvance { drawable.present() }
            return frame
        }
        // guide-region-end

        /// Dotyk w punktach widoku → punkt świata (ten sam widok kamery co w ostatniej klatce) → scena.
        func touch(_ phase: UITouch.Phase, at location: CGPoint, in view: UIView) {
            guard let scene, let world, let lastViewport, view.bounds.width > 0, view.bounds.height > 0,
                  let point = try? lastViewport.worldPoint(
                    for: [Float(location.x), Float(location.y)],
                    in: [Float(view.bounds.width), Float(view.bounds.height)]) else { return }
            switch phase {
            case .began: Task { @MainActor in await scene.touchBegan(at: point, world: world) }
            case .moved: scene.touchMoved(to: point, world: world)
            default: scene.touchEnded(world: world)
            }
        }
    }
}
