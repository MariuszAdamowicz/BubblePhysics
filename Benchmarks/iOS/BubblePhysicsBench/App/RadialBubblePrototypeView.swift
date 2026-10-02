import BubblePhysics
import BubblePhysicsMetal
import MetalKit
import SwiftUI

struct RadialBubblePrototypeView: UIViewRepresentable {
    @ObservedObject var model: PrototypeViewModel

    func makeCoordinator() -> RadialBubblePrototypeCoordinator { .init(model: model) }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.depthStencilPixelFormat = .stencil8
        view.clearColor = MTLClearColor(red: 0.03, green: 0.04, blue: 0.07, alpha: 1)
        view.preferredFramesPerSecond = 60
        view.delegate = context.coordinator
        context.coordinator.attach(view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.synchronize(model)
    }
}

@MainActor final class RadialBubblePrototypeCoordinator: NSObject, MTKViewDelegate {
    private weak var model: PrototypeViewModel?
    private var simulation: MetalRadialWorldSimulation?
    private var renderer: MetalRadialWorldRenderer?
    private var queue: MTLCommandQueue?
    private var generation = -1
    private var start = CACurrentMediaTime()
    private var telemetry = FrameTelemetry()
    private var lastPublish = 0.0
    private var frameInFlight = false
    private var scene: RadialDiagnosticScene?
    private var targetRadii: [BubbleID: Float] = [:]
    private var activatedBubbleCount = 0
    private var frameIndex = 0

    init(model: PrototypeViewModel) {
        self.model = model
    }

    func attach(_ view: MTKView) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        renderer = try? MetalRadialWorldRenderer(
            device: device,
            pixelFormat: view.colorPixelFormat,
            worldBounds: RadialDiagnosticSceneFactory.bounds
        )
        rebuild(device)
    }

    func synchronize(_ model: PrototypeViewModel) {
        guard generation != model.resetGeneration, let device = queue?.device else { return }
        generation = model.resetGeneration
        rebuild(device)
    }

    private func rebuild(_ device: MTLDevice) {
        do {
            let scene = try RadialDiagnosticSceneFactory.make()
            let simulation = try MetalRadialWorldSimulation(device: device, world: scene.world)
            targetRadii = Dictionary(uniqueKeysWithValues: scene.world.bubbles.map { ($0.id, $0.targetRadius) })
            for bubble in scene.world.bubbles { simulation.setTargetRadius(0, for: bubble.id) }
            if let first = scene.world.bubbles.first {
                simulation.setTargetRadius(targetRadii[first.id] ?? 0, for: first.id)
                activatedBubbleCount = 1
            }
            try renderer?.rebuildScene(labels: scene.labels)
            self.scene = scene
            self.simulation = simulation
            telemetry.reset()
            model?.telemetry = telemetry.snapshot
            model?.errorMessage = nil
            start = CACurrentMediaTime()
            frameIndex = 0
        } catch {
            model?.errorMessage = "Błąd prototypu radialnego: \(error)"
        }
    }

    func draw(in view: MTKView) {
        guard
            !frameInFlight,
            let model,
            !model.isPaused,
            model.errorMessage == nil,
            let simulation,
            let renderer,
            let queue,
            let command = queue.makeCommandBuffer(),
            let drawable = view.currentDrawable
        else { return }
        frameInFlight = true
        let began = CACurrentMediaTime()
        do {
            let triangleState = KinematicTriangleMotion.default.sample(
                time: CACurrentMediaTime() - start,
                isPaused: model.trianglePaused
            )
            let triangle = makeTriangle(state: triangleState)
            activateNextBubbleIfNeeded(elapsed: CACurrentMediaTime() - start, simulation: simulation)
            let worldBeforeStep = simulation.world
            let substeps = MetalRadialWorldSimulation.substepCount(
                for: worldBeforeStep, polygons: [triangle], deltaTime: 1 / 60
            )
            let frame = try simulation.encodeStep(
                bounds: scene?.bounds ?? RadialDiagnosticSceneFactory.bounds,
                polygons: [triangle],
                deltaTime: 1 / 120,
                commandBuffer: command
            )
            let vertices = triangle.worldVertices.map { SIMD2($0.x, $0.y) }
            let renderBegan = CACurrentMediaTime()
            _ = try renderer.encode(
                frame: frame,
                polygonVertices: vertices,
                diagnostics: model.diagnostics,
                renderPass: view.currentRenderPassDescriptor,
                drawableSize: view.drawableSize,
                commandBuffer: command
            )
            let renderMilliseconds = (CACurrentMediaTime() - renderBegan) * 1_000
            command.present(drawable)
            command.addCompletedHandler { [weak self] completed in
                Task { @MainActor in
                    self?.complete(
                        simulation: simulation,
                        frame: frame,
                        command: completed,
                        began: began,
                        renderMilliseconds: renderMilliseconds,
                        substeps: substeps
                    )
                }
            }
            command.commit()
        } catch {
            frameInFlight = false
            model.errorMessage = "Błąd radialnego Metal: \(error)"
        }
    }

    private func complete(
        simulation: MetalRadialWorldSimulation,
        frame: MetalRadialWorldFrameResources,
        command: MTLCommandBuffer,
        began: Double,
        renderMilliseconds: Double,
        substeps: Int
    ) {
        defer { frameInFlight = false }
        do {
            try simulation.complete(frame: frame, commandBuffer: command)
            let milliseconds = (CACurrentMediaTime() - began) * 1_000
            frameIndex += 1
            let decisions = RadialWorldRemesher.plan(
                world: simulation.world, policy: .default, frameIndex: frameIndex
            )
            if !decisions.isEmpty { try simulation.applyRemesh(decisions) }
            let state = simulation.world
            let radial = RadialWorldFrameMetrics(
                world: state,
                frame: frame,
                gpuFrameMilliseconds: milliseconds,
                remeshOperationCount: decisions.count,
                substepCount: substeps
            )
            telemetry.record(
                milliseconds: milliseconds,
                timings: .init(
                    contourMilliseconds: max(0, milliseconds - renderMilliseconds),
                    remeshingMilliseconds: 0,
                    renderingMilliseconds: renderMilliseconds
                ),
                counters: .init(
                    particleCount: state.totalSensorCount,
                    segmentCount: state.totalSensorCount,
                    candidatePairCount: frame.candidatePairCount,
                    contactCount: frame.contactCount + frame.pairContactCount,
                    remeshOperationCount: decisions.count,
                    didOverflow: radial.didOverflow,
                    didEncounterNonFinite: radial.didEncounterNonFinite
                ),
                worldRadial: radial
            )
            let now = CACurrentMediaTime()
            if now - lastPublish > 0.25 {
                lastPublish = now
                model?.telemetry = telemetry.snapshot
            }
        } catch {
            model?.errorMessage = "Sesja radialna zatrzymana: \(error)"
        }
    }

    private func activateNextBubbleIfNeeded(elapsed: Double, simulation: MetalRadialWorldSimulation) {
        guard let scene else { return }
        let requiredCount = min(scene.world.bubbles.count, 1 + Int(elapsed / 1.5))
        while activatedBubbleCount < requiredCount {
            let bubble = scene.world.bubbles[activatedBubbleCount]
            simulation.setTargetRadius(targetRadii[bubble.id] ?? bubble.targetRadius, for: bubble.id)
            activatedBubbleCount += 1
        }
    }

    private func makeTriangle(state: KinematicTriangleState) -> SimulationPolygonSnapshot {
        let local = [
            Vector2(x: -34, y: 26),
            Vector2(x: 34, y: 26),
            Vector2(x: 0, y: -38)
        ]
        let cosine = cos(state.angleRadians)
        let sine = sin(state.angleRadians)
        let vertices = local.map { point in
            Vector2(
                x: point.x * cosine - point.y * sine + state.position.x,
                y: point.x * sine + point.y * cosine + state.position.y
            )
        }
        return SimulationPolygonSnapshot(
            id: PolygonID(rawValue: 1),
            mode: .kinematic,
            worldVertices: vertices,
            position: state.position,
            linearVelocity: state.linearVelocity,
            angularVelocity: state.angularVelocity
        )
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
}
