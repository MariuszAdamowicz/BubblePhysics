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
    private var simulation: MetalRadialSimulation?
    private var renderer: MetalRadialRenderer?
    private var queue: MTLCommandQueue?
    private var generation = -1
    private var start = CACurrentMediaTime()
    private var telemetry = FrameTelemetry()
    private var lastPublish = 0.0
    private var frameInFlight = false

    init(model: PrototypeViewModel) {
        self.model = model
    }

    func attach(_ view: MTKView) {
        guard let device = view.device else { return }
        queue = device.makeCommandQueue()
        renderer = try? MetalRadialRenderer(
            device: device,
            pixelFormat: view.colorPixelFormat,
            worldBounds: PrototypeSceneFactory.bounds,
            label: "2"
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
            let state = RadialBubbleState.collapsed(
                id: BubbleID(rawValue: 1),
                center: Vector2(x: 187.5, y: 406),
                targetRadius: 150,
                maxSegmentLength: 8,
                mass: 20
            )
            simulation = try MetalRadialSimulation(device: device, state: state)
            telemetry.reset()
            model?.telemetry = telemetry.snapshot
            model?.errorMessage = nil
            start = CACurrentMediaTime()
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
            let frame = try simulation.encodeStep(
                bounds: PrototypeSceneFactory.bounds,
                polygons: [triangle],
                deltaTime: 1 / 60,
                commandBuffer: command
            )
            let vertices = triangle.worldVertices.map { SIMD2($0.x, $0.y) }
            _ = try renderer.encode(
                frame: frame,
                polygonVertices: vertices,
                diagnostics: model.diagnostics,
                renderPass: view.currentRenderPassDescriptor,
                drawableSize: view.drawableSize,
                commandBuffer: command
            )
            command.present(drawable)
            command.addCompletedHandler { [weak self] completed in
                Task { @MainActor in
                    self?.complete(
                        simulation: simulation,
                        frame: frame,
                        command: completed,
                        began: began
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
        simulation: MetalRadialSimulation,
        frame: MetalRadialFrameResources,
        command: MTLCommandBuffer,
        began: Double
    ) {
        defer { frameInFlight = false }
        do {
            try simulation.complete(frame: frame, commandBuffer: command)
            let milliseconds = (CACurrentMediaTime() - began) * 1_000
            let state = simulation.state
            let radial = RadialFrameMetrics(
                state: state,
                frame: frame,
                gpuFrameMilliseconds: milliseconds
            )
            telemetry.record(
                milliseconds: milliseconds,
                timings: .init(
                    contourMilliseconds: milliseconds,
                    remeshingMilliseconds: 0,
                    renderingMilliseconds: 0
                ),
                counters: .init(
                    particleCount: state.sensors.count,
                    segmentCount: state.sensors.count,
                    candidatePairCount: 0,
                    contactCount: frame.contactCount,
                    remeshOperationCount: 0,
                    didOverflow: radial.didOverflow,
                    didEncounterNonFinite: radial.didEncounterNonFinite
                ),
                radial: radial
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
