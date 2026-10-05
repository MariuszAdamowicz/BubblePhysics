import Foundation
import Dispatch
import Metal
@_spi(ReferenceMetal) import BubblePhysicsReference

@MainActor
protocol ReferenceMetalFrameExecuting {
    func executeFrame(snapshot: ReferenceMetalSnapshot, scenarioStep: Int) async throws -> ReferenceMetalWorldFrame
}

struct ReferenceMetalWorldFrame {
    var bubbles: [ReferenceBubble]
    var contacts: [ReferenceContact]
    var contours: [ReferenceBubbleID: [ReferenceVector2]]
    var renderData: [SIMD4<Float>]
    var report: ReferenceWorldStepReport
    var telemetry: ReferenceMetalFrameTelemetry
}

enum ReferenceMetalWorldError: Error {
    case unsupportedRuntime, unavailable, invalidFrame, guardFailed, frameInFlight
}

/// Explicit iOS runtime selection. Main-actor ownership serializes the runner's
/// resource lifetime across suspension; a concurrent call uses a whole CPU frame.
@MainActor
public final class ReferenceMetalWorldRunner {
    public private(set) var telemetry = ReferenceMetalFrameTelemetry()
    public private(set) var contours: [ReferenceBubbleID: [ReferenceVector2]] = [:]
    public private(set) var renderData: [SIMD4<Float>] = []
    public private(set) var firstGPUFailure: ReferenceMetalGPUFailure?
    /// The runner owns one session. Only creating a new runner clears this latch.
    public private(set) var fatalGPUFailure: ReferenceMetalGPUFailure?
    private let backend: ReferenceSimulationBackend
    private let executor: (any ReferenceMetalFrameExecuting)?
    private let availabilityError: ReferenceMetalWorldError?
    private var inFlight = false

    public init(backend: ReferenceSimulationBackend = .cpu) {
        self.backend = backend
        #if os(iOS)
        executor = backend == .metal ? ReferenceMetalSolver() : nil
        availabilityError = backend == .metal && executor == nil ? .unavailable : nil
        #else
        executor = nil
        availabilityError = backend == .metal ? .unsupportedRuntime : nil
        #endif
    }

    // Package tests may exercise the actual pipelines on a host with Metal.
    // This entry point is deliberately not part of public runtime selection.
    init(executor: any ReferenceMetalFrameExecuting) {
        backend = .metal
        self.executor = executor
        availabilityError = nil
    }

    public func step(world: inout ReferenceWorld, scenarioStep: Int) async -> ReferenceWorldStepReport {
        let start = DispatchTime.now().uptimeNanoseconds
        if backend == .cpu { return cpuFrame(world: &world, start: start, reason: nil) }
        if let failure = fatalGPUFailure {
            return cpuFrame(world: &world, start: start, reason: "GPU session disabled: \(failure)", gpuFailure: failure)
        }
        guard !inFlight else {
            return cpuFrame(world: &world, start: start, reason: String(describing: ReferenceMetalWorldError.frameInFlight))
        }
        guard let executor else {
            return cpuFrame(world: &world, start: start, reason: String(describing: availabilityError ?? .unavailable))
        }
        inFlight = true
        defer { inFlight = false }
        let snapshot = ReferenceMetalSnapshot(world: world)
        do {
            let frame = try await executor.executeFrame(snapshot: snapshot, scenarioStep: scenarioStep)
            try Task.checkCancellation()
            try Self.validate(frame, snapshot: snapshot)
            // No await or throwing operation in this publication region. State,
            // contours, rendering and telemetry become visible together.
            world.publishPreparedFrame(bubbles: frame.bubbles, contacts: frame.contacts, contours: frame.contours)
            contours = frame.contours
            renderData = frame.renderData
            telemetry = frame.telemetry
            return frame.report
        } catch {
            let failure: ReferenceMetalGPUFailure?
            if let gpuError = error as? ReferenceMetalGPUFailure {
                failure = gpuError
            } else if (error as NSError).domain == MTLCommandBufferErrorDomain {
                failure = .init(stage: "executeFrame", scenarioStep: scenarioStep, error: error as NSError)
            } else {
                failure = nil
            }
            if let failure {
                if firstGPUFailure == nil { firstGPUFailure = failure }
                if failure.isFatal { fatalGPUFailure = failure }
            }
            // The world is still the original frame input. CPU reruns its entire
            // next step, including prediction, events, solve and post-solve.
            return cpuFrame(world: &world, start: start, reason: failure?.description ?? String(describing: error), gpuFailure: failure)
        }
    }

    private func cpuFrame(world: inout ReferenceWorld, start: UInt64, reason: String?, gpuFailure: ReferenceMetalGPUFailure? = nil) -> ReferenceWorldStepReport {
        let report = world.step()
        contours = [:]
        renderData = []
        telemetry = .init(backend: .cpu,
            frameMilliseconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000,
            finalResidual: report.solver.finalResidualNorm, newtonIterations: report.solver.iterations,
            pcgIterations: report.solver.pcgIterationCount,
            didEncounterNonFinite: report.hasNonFiniteState, fallbackReason: reason, gpuFailure: gpuFailure)
        return report
    }

    private static func validate(_ frame: ReferenceMetalWorldFrame, snapshot: ReferenceMetalSnapshot) throws {
        guard frame.bubbles.count == snapshot.bubbles.count,
              frame.bubbles.map({ Int64($0.id.rawValue) }) == snapshot.bubbles.map({ $0.identity.x }),
              frame.telemetry.backend == .metal, frame.telemetry.fallbackReason == nil,
              !frame.telemetry.didEncounterNonFinite, !frame.report.hasNonFiniteState,
              frame.telemetry.frameMilliseconds.isFinite, frame.telemetry.gpuMilliseconds.isFinite,
              frame.telemetry.finalResidual.isFinite,
              frame.bubbles.allSatisfy({ $0.center.isFinite && $0.previousCenter.isFinite && $0.velocity.isFinite && $0.rotation.isFinite && $0.angularVelocity.isFinite }),
              frame.contacts.allSatisfy({ $0.normal.isFinite && $0.pointQ.isFinite && $0.penetration.isFinite && $0.pressure.isFinite }),
              frame.contours.count == snapshot.bubbles.count,
              frame.contours.values.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isFinite) }),
              frame.renderData.count == snapshot.bubbles.count,
              frame.renderData.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        else { throw ReferenceMetalWorldError.invalidFrame }
        let polygons = Dictionary(grouping: snapshot.segments.filter { $0.flags.y != 0 }, by: { $0.identity.y })
        for (index, bubble) in frame.bubbles.enumerated() {
            let packed = snapshot.bubbles[index]
            guard bubble.mass == packed.physical.x, bubble.inverseMass == packed.physical.y,
                  bubble.targetRadius == packed.physical.z, bubble.stiffness == packed.physical.w,
                  bubble.previousCenter == .init(x: snapshot.centers[index].x, y: snapshot.centers[index].y),
                  frame.contours[bubble.id] != nil,
                  frame.renderData[index] == SIMD4(bubble.center.x, bubble.center.y, bubble.targetRadius, bubble.rotation)
            else { throw ReferenceMetalWorldError.invalidFrame }
            for segment in snapshot.segments where segment.flags.z != 0 {
                let a = ReferenceVector2(x: segment.current.x, y: segment.current.y)
                let edge = ReferenceVector2(x: segment.current.z - a.x, y: segment.current.w - a.y)
                let normal = ReferenceVector2(x: -edge.y, y: edge.x).normalized(or: .init(x: 0, y: 1)) * segment.collision.x
                guard (bubble.center - a).dot(normal) >= -snapshot.configuration.positionTolerance
                else { throw ReferenceMetalWorldError.guardFailed }
            }
            for edges in polygons.values where edges.count >= 3 {
                var inside = false
                for segment in edges {
                    let a = ReferenceVector2(x: segment.current.x, y: segment.current.y)
                    let b = ReferenceVector2(x: segment.current.z, y: segment.current.w)
                    guard (a.y > bubble.center.y) != (b.y > bubble.center.y) else { continue }
                    let crossing = (b.x - a.x) * (bubble.center.y - a.y) / (b.y - a.y) + a.x
                    if bubble.center.x < crossing { inside.toggle() }
                }
                guard !inside else { throw ReferenceMetalWorldError.guardFailed }
            }
        }
    }
}
