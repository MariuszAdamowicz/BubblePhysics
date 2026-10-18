import Foundation
import BubblePhysicsReference

/// Wspólny wynik dla istniejącego renderera CPU i natywnego backendu GPU.
public struct VisualSimulationFrame: Sendable {
    public let snapshot: ReferenceVisualSnapshot
    public let selectedBackend: ReferenceSimulationBackend
    public let actualBackend: ReferenceSimulationBackend
    public let fallbackReason: String?
    public let gpuMilliseconds: Double
    public let containmentCount: Int
    public let hasNonFiniteState: Bool
}

/// Adapter podglądu. Jedno wywołanie advance publikuje wyłącznie ukończone kroki.
@MainActor
public final class VisualSimulationDriver {
    public private(set) var frame: VisualSimulationFrame
    private var backend: ReferenceSimulationBackend
    private var density: ReferenceVisualDensity
    private var scene: ReferenceVisualScene
    private var cpu: ReferenceVisualRunner
    private var native: NativeMetalWorldRunner
    private let makeNative: () -> NativeMetalWorldRunner
    private var inFlight = false
    private var generation = 0
    private var lastPresentationTime: Double?
    private var accumulator = 0.0
    private var simulationTime = 0.0
    private var stepNumber = 0
    private var polygonCenter = ReferenceVisualSceneFactory.initialPolygonCenter
    private var requestedPolygonCenter = ReferenceVisualSceneFactory.initialPolygonCenter
    private var containment = ReferenceContainmentTracker(positionTolerance: ReferenceConfiguration.default.positionTolerance)

    public convenience init(backend: ReferenceSimulationBackend = .nativeMetal,
                            density: ReferenceVisualDensity = .twentyFour) throws {
        let factory = {
            NativeMetalWorldRunner(configuration: .init(solverIterationCount: 4))
                ?? NativeMetalWorldRunner(executor: nil, configuration: .init(solverIterationCount: 4))
        }
        try self.init(backend: backend, density: density, nativeRunner: factory(), runnerFactory: factory)
    }

    init(backend: ReferenceSimulationBackend = .nativeMetal, density: ReferenceVisualDensity = .twentyFour,
         nativeRunner: NativeMetalWorldRunner, runnerFactory: (() -> NativeMetalWorldRunner)? = nil) throws {
        self.backend = backend == .cpu ? .cpu : .nativeMetal
        self.density = density
        self.scene = try ReferenceVisualSceneFactory.make(density: density)
        self.cpu = try ReferenceVisualRunner(density: density)
        self.native = nativeRunner
        self.makeNative = runnerFactory ?? { nativeRunner }
        var initial = cpu
        frame = .init(snapshot: initial.advance(to: 0), selectedBackend: self.backend,
                      actualBackend: self.backend, fallbackReason: nil, gpuMilliseconds: 0,
                      containmentCount: 0, hasNonFiniteState: false)
    }

    public func reset() {
        generation += 1
        native = makeNative()
        scene = try! ReferenceVisualSceneFactory.make(density: density)
        cpu = try! ReferenceVisualRunner(density: density)
        lastPresentationTime = nil; accumulator = 0; simulationTime = 0; stepNumber = 0
        polygonCenter = ReferenceVisualSceneFactory.initialPolygonCenter
        requestedPolygonCenter = polygonCenter
        containment = ReferenceContainmentTracker(positionTolerance: scene.world.configuration.positionTolerance)
        var initial = cpu
        frame = .init(snapshot: initial.advance(to: 0), selectedBackend: backend, actualBackend: backend,
                      fallbackReason: nil, gpuMilliseconds: 0, containmentCount: 0, hasNonFiniteState: false)
    }

    public func setBackend(_ value: ReferenceSimulationBackend) {
        backend = value == .cpu ? .cpu : .nativeMetal
        reset()
    }

    public func setDensity(_ value: ReferenceVisualDensity) { density = value; reset() }

    public func movePolygon(to point: ReferenceVector2) {
        guard point.isFinite else { return }
        requestedPolygonCenter = .init(x: min(330, max(45, point.x)), y: min(650, max(50, point.y)))
        cpu.movePolygon(to: requestedPolygonCenter)
    }

    /// Uwzględnia letterboxing renderera i odrzuca nieprawidłowe wejście UI.
    public static func worldPoint(x: Double, y: Double, width: Double, height: Double) -> ReferenceVector2? {
        guard [x, y, width, height].allSatisfy(\.isFinite), width > 0, height > 0 else { return nil }
        let scale = min(width / 375, height / 700)
        let point = ReferenceVector2(x: Float((x - (width - 375 * scale) * 0.5) / scale),
                                    y: Float((y - (height - 700 * scale) * 0.5) / scale))
        return point.isFinite ? point : nil
    }

    public func advance(to presentationTime: Double) async -> VisualSimulationFrame {
        guard presentationTime.isFinite, !inFlight else { return frame }
        if backend == .cpu {
            let snapshot = cpu.advance(to: presentationTime)
            containment.observe(snapshot.bubbles)
            frame = .init(snapshot: snapshot, selectedBackend: .cpu, actualBackend: .cpu,
                          fallbackReason: nil, gpuMilliseconds: 0, containmentCount: containment.maximumConsecutiveFrames,
                          hasNonFiniteState: snapshot.lastReport.hasNonFiniteState)
            return frame
        }
        guard let previous = lastPresentationTime else { lastPresentationTime = presentationTime; return frame }
        let dt = ReferenceVisualRunner.fixedTimeStep
        accumulator += min(max(0, presentationTime - previous), dt * Double(ReferenceVisualRunner.maximumCatchUpSteps))
        lastPresentationTime = presentationTime
        guard accumulator + 1e-12 >= dt else { return frame }
        inFlight = true
        defer { inFlight = false }
        let currentGeneration = generation
        var steps = 0
        while accumulator + 1e-12 >= dt && steps < ReferenceVisualRunner.maximumCatchUpSteps {
            let oldVertices = ReferenceVisualSceneFactory.polygonVertices(localVertices: scene.polygonLocalVertices, center: polygonCenter)
            let delta = requestedPolygonCenter - polygonCenter
            let nextCenter = polygonCenter + (delta.length > 18 ? delta * (18 / delta.length) : delta)
            let vertices = ReferenceVisualSceneFactory.polygonVertices(localVertices: scene.polygonLocalVertices, center: nextCenter)
            var world = scene.world
            for index in vertices.indices {
                world.updateSegment(.kinematicSegment(id: scene.polygonSegmentIDs[index],
                    previousA: oldVertices[index], previousB: oldVertices[(index + 1) % 3],
                    currentA: vertices[index], currentB: vertices[(index + 1) % 3], timeStep: Float(dt),
                    ownerID: scene.polygonOwnerID, collisionMode: .twoSided))
            }
            let report = await native.step(world: &world, scenarioStep: stepNumber)
            guard generation == currentGeneration else { return frame }
            scene.world = world; polygonCenter = nextCenter
            stepNumber += 1; simulationTime += dt; accumulator -= dt; steps += 1
            containment.observe(world.bubbles)
            // Na sukcesie są to dokładnie kontury opublikowane przez runner GPU.
            let contours = native.telemetry.backend == .nativeMetal ? native.contours
                : Dictionary(uniqueKeysWithValues: world.bubbles.map { ($0.id, world.contour(for: $0.id)) })
            let snapshot = ReferenceVisualSnapshot(bubbles: world.bubbles, contours: contours,
                triangleVertices: vertices, contacts: world.contacts.contacts, lastReport: report,
                simulationTime: simulationTime, stepsExecuted: steps, valuesByBubbleID: scene.valuesByBubbleID)
            frame = .init(snapshot: snapshot, selectedBackend: backend, actualBackend: native.telemetry.backend,
                fallbackReason: native.telemetry.fallbackReason, gpuMilliseconds: native.telemetry.gpuMilliseconds,
                containmentCount: containment.maximumConsecutiveFrames,
                hasNonFiniteState: report.hasNonFiniteState || native.telemetry.didEncounterNonFinite)
        }
        return frame
    }
}
