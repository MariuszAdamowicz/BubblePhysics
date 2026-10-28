import BubblePhysics
import Metal
import QuartzCore
import Foundation

public struct PublicWorldStressTiming: Sendable {
    public let p95Milliseconds: Double
    public let maximumMilliseconds: Double
}

public struct PublicWorldStressScenarioReport: Sendable {
    public let name: String
    public let warmupFrames: Int
    public let measuredFrames: Int
    public let semanticInputFrames: Int
    public let cpuInputToEncoding: PublicWorldStressTiming
    public let gpuCommandBuffer: PublicWorldStressTiming
    public let fullFrameInputToPresentation: PublicWorldStressTiming
}

public struct PublicWorldStressReport: Sendable {
    public let deviceName: String
    public let scenarios: [PublicWorldStressScenarioReport]
    public let solverIterationLimit: Int
    public let guardCorrections: Int
    public let nonFiniteFrames: Int
    public let fallbackFrames: Int
    public let commandBufferErrors: Int
    public let overflowEvents: Int
    public let contourCPUReadbacks: Int
    public let diagnostics: [String]

    public var safetyPassed: Bool {
        nonFiniteFrames == 0 && fallbackFrames == 0 && commandBufferErrors == 0
            && overflowEvents == 0 && contourCPUReadbacks == 0
    }

    public var text: String {
        var lines = ["path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer",
            "device=\(deviceName)", "scenarios=\(scenarios.count); solver_iteration_limit=\(solverIterationLimit)"]
        for scenario in scenarios {
            lines.append("scenario=\(scenario.name); warmup=\(scenario.warmupFrames); measured=\(scenario.measuredFrames); semantic_input_frames=\(scenario.semanticInputFrames)")
            lines.append("cpu_input_to_encoding_p95_ms=\(format(scenario.cpuInputToEncoding.p95Milliseconds)); cpu_input_to_encoding_max_ms=\(format(scenario.cpuInputToEncoding.maximumMilliseconds))")
            lines.append("gpu_command_buffer_p95_ms=\(format(scenario.gpuCommandBuffer.p95Milliseconds)); gpu_command_buffer_max_ms=\(format(scenario.gpuCommandBuffer.maximumMilliseconds))")
            lines.append("full_frame_input_to_presentation_p95_ms=\(format(scenario.fullFrameInputToPresentation.p95Milliseconds)); full_frame_input_to_presentation_max_ms=\(format(scenario.fullFrameInputToPresentation.maximumMilliseconds))")
            lines.append("ceo_full_frame_gate_ms=16.67; decision_required=\(scenario.measuredFrames == 0 || !scenario.fullFrameInputToPresentation.p95Milliseconds.isFinite || scenario.fullFrameInputToPresentation.p95Milliseconds > 16.67 || !safetyPassed)")
        }
        lines.append("guard_corrections=\(guardCorrections); non_finite_frames=\(nonFiniteFrames); fallback_frames=\(fallbackFrames); command_buffer_errors=\(commandBufferErrors); overflow_events=\(overflowEvents); contour_cpu_readbacks=\(contourCPUReadbacks); safety=\(safetyPassed ? "pass" : "fail")")
        lines.append(contentsOf: diagnostics)
        return lines.joined(separator: "\n")
    }

    private func format(_ value: Double) -> String { String(format: "%.4f", value) }
}

@MainActor
public enum PublicWorldStressBenchmark {
    /// iOS acceptance protocol: Release hardware, 120 warmups and 300 measured frames per scenario.
    public static func measure(device: MTLDevice,
                               drawableProvider: @escaping @MainActor () async throws -> CAMetalDrawable,
                               progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws
        -> PublicWorldStressReport {
        try await run(device: device, warmupFrames: 120, measuredFrames: 300,
            drawableProvider: drawableProvider, progress: progress)
    }

    package static func run(device: MTLDevice, warmupFrames: Int, measuredFrames: Int,
                            drawableProvider: (@MainActor () async throws -> CAMetalDrawable)? = nil,
                            presentationWaiter: (@MainActor () async -> Void)? = nil,
                            populationObserver: (@MainActor (String, Int) -> Void)? = nil,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        let names = ["semantic_spawn", "drag", "merge", "dense_arena"]
        let total = names.count * (warmupFrames + measuredFrames)
        var completed = 0
        var reports: [PublicWorldStressScenarioReport] = []
        var guardCorrections = 0, nonFiniteFrames = 0, fallbackFrames = 0
        var commandBufferErrors = 0, overflowEvents = 0, readbacks = 0
        var diagnostics: [String] = []
        for name in names {
            let configuration = try makeConfiguration()
            let world = try BubbleWorld.makeBenchmarkWorld(configuration: configuration,
                device: device, solverIterationLimit: 4)
            let renderer = try BubblePhysicsMetalRender(device: device)
            let materialID = PhysicsMaterialID(rawValue: 1)
            let polygonMaterialID = PhysicsMaterialID(rawValue: 2)
            let styleID = RenderStyleID(rawValue: 1)
            var transaction = WorldTransaction()
                .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble))
                .updatePhysicsMaterial(polygonMaterialID, material: try PhysicsMaterial(kind: .polygon))
                .updateRenderStyle(styleID, style: try RenderStyle())
            if name == "dense_arena" {
                for index in 0..<300 {
                    let column = index % 15, row = index / 15
                    let horizontalSpacing: Float = 345 / 15
                    let verticalSpacing: Float = 670 / 20
                    let radius = min(horizontalSpacing, verticalSpacing) * 0.54
                    transaction = transaction.add(.bubble(try BubbleDescriptor(
                        id: ObjectID(rawValue: UInt64(index + 1)),
                        position: [15 + (Float(column) + 0.5) * horizontalSpacing,
                            15 + (Float(row) + 0.5) * verticalSpacing],
                        targetRadius: radius, mass: max(1, radius * radius * 0.02),
                        physicsMaterialID: materialID, renderStyleID: styleID)))
                }
            }
            if name == "merge" {
                for index in 0..<2 {
                    transaction = transaction.add(.bubble(try BubbleDescriptor(
                        id: ObjectID(rawValue: UInt64(index + 1)), position: [150 + Float(index) * 24, 350],
                        targetRadius: 12, mass: 3, physicsMaterialID: materialID, renderStyleID: styleID)))
                }
            }
            if name == "drag" || name == "semantic_spawn" {
                transaction = transaction.add(.bubble(try BubbleDescriptor(id: ObjectID(rawValue: 1),
                    position: name == "drag" ? [180, 350] : [45, 60], targetRadius: 12, mass: 3,
                    physicsMaterialID: materialID, renderStyleID: styleID)))
            }
            world.submit(transaction)
            let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
                width: 375, height: 700, mipmapped: false)
            textureDescriptor.usage = .renderTarget
            textureDescriptor.storageMode = .private
            guard let texture = device.makeTexture(descriptor: textureDescriptor),
                  let queue = device.makeCommandQueue() else { throw StressBenchmarkError.metalUnavailable }
            var cpu: [Double] = [], gpu: [Double] = [], full: [Double] = []
            var semanticInputFrames = 0
            var scenarioErrors = 0
            var pendingSpawnCleanup: [ObjectID] = []
            var lastMergeResultID: ObjectID?
            let scenarioTotal = warmupFrames + measuredFrames
            for index in 0..<scenarioTotal {
                try Task.checkCancellation()
                let inputStart = DispatchTime.now().uptimeNanoseconds
                var hasSemanticInput = false
                switch name {
                case "semantic_spawn" where index >= warmupFrames:
                    var spawn = WorldTransaction()
                    for id in pendingSpawnCleanup { spawn = spawn.remove(id) }
                    pendingSpawnCleanup.removeAll(keepingCapacity: true)
                    world.submit(spawn.spawnBubble(SpawnBubbleRequest(value: 3, arena: "round", seed: 733)))
                    hasSemanticInput = true
                case "drag":
                    let id = ObjectID(rawValue: 1)
                    let target = WorldPoint(180 + Float(index % 20), 350)
                    if index == 0 { world.submit(WorldTransaction().beginPlayerDrive(id, target: target)) }
                    else if index == scenarioTotal - 1 { world.submit(WorldTransaction().endPlayerDrive(id)) }
                    else { world.submit(WorldTransaction().updatePlayerDrive(id, target: target)) }
                    hasSemanticInput = index >= warmupFrames
                case "merge" where index >= warmupFrames:
                    let mergeIndex = index - warmupFrames
                    let sourceID = UInt64(1 + mergeIndex * 3)
                    var merge = WorldTransaction()
                    if let lastMergeResultID { merge = merge.remove(lastMergeResultID) }
                    world.submit(merge.mergeBubbles(
                        [ObjectID(rawValue: sourceID), ObjectID(rawValue: sourceID + 1)],
                        result: BubbleResult(id: ObjectID(rawValue: sourceID + 2), physicsMaterialID: materialID,
                            renderStyleID: styleID, bubblePresentation: try BubblePresentation(value: 4, isGrabbed: false))))
                    lastMergeResultID = ObjectID(rawValue: sourceID + 2)
                    if mergeIndex + 1 < measuredFrames {
                        let nextID = sourceID + 3
                        let nextX = Float((mergeIndex + 1) % 7) * 45 + 30
                        let nextY = Float((mergeIndex + 1) / 7 % 9) * 65 + 60
                        var additions = WorldTransaction()
                        for pairIndex in 0..<2 {
                            additions = additions.add(.bubble(try BubbleDescriptor(
                                id: ObjectID(rawValue: nextID + UInt64(pairIndex)),
                                position: [nextX + Float(pairIndex) * 24, nextY], targetRadius: 12, mass: 3,
                                physicsMaterialID: materialID, renderStyleID: styleID)))
                        }
                        world.submit(additions)
                    }
                    hasSemanticInput = true
                default: break
                }
                if hasSemanticInput { semanticInputFrames += 1 }
                guard let command = queue.makeCommandBuffer() else { throw StressBenchmarkError.metalUnavailable }
                let drawable = try await drawableProvider?()
                let presentation = drawable.map { drawable in
                    let latch = DrawablePresentationLatch()
                    drawable.addPresentedHandler { _ in latch.signal() }
                    return latch
                }
                let pass = MTLRenderPassDescriptor()
                pass.colorAttachments[0].texture = drawable?.texture ?? texture
                pass.colorAttachments[0].loadAction = .clear
                pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
                pass.colorAttachments[0].storeAction = .store
                var inputToEncodingMilliseconds: Double?
                let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
                    try renderer.encode(world: world, viewport: Viewport(center: [187.5, 350], size: [375, 700]),
                        commandBuffer: command, renderPassDescriptor: pass)
                    if let drawable { command.present(drawable) }
                    inputToEncodingMilliseconds = Double(DispatchTime.now().uptimeNanoseconds - inputStart) / 1_000_000
                }
                populationObserver?(name, world.renderState?.items.compactMap { $0 }.count ?? 0)
                if command.status == .completed {
                    if let presentationWaiter { await presentationWaiter() }
                    else { await presentation?.wait() }
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - inputStart) / 1_000_000
                if command.status != .completed || world.diagnostics.lastAdvanceIssue != nil || frame.stepIndex != UInt64(index + 1) {
                    commandBufferErrors += 1; scenarioErrors += 1
                    diagnostics.append("error scenario=\(name) step=\(frame.stepIndex) expected=\(index + 1) status=\(command.status) issue=\(String(describing: world.diagnostics.lastAdvanceIssue))")
                }
                if name == "semantic_spawn" && index >= warmupFrames {
                    pendingSpawnCleanup = frame.transactionReceipts.flatMap(\.createdObjectIDs)
                }
                if frame.eventOverflow.droppedCount > 0 { overflowEvents += frame.eventOverflow.droppedCount }
                if let telemetry = world.benchmarkTelemetry {
                    guardCorrections += telemetry.guardCorrectionCount
                    if telemetry.didEncounterNonFinite { nonFiniteFrames += 1 }
                    if telemetry.fallbackReason != nil { fallbackFrames += 1 }
                    if index >= warmupFrames {
                        gpu.append(telemetry.gpuMilliseconds)
                        if let inputToEncodingMilliseconds { cpu.append(inputToEncodingMilliseconds) }
                        else { commandBufferErrors += 1; scenarioErrors += 1 }
                    }
                } else {
                    commandBufferErrors += 1; scenarioErrors += 1
                    diagnostics.append("error scenario=\(name) telemetry=unavailable step=\(frame.stepIndex) issue=\(String(describing: world.diagnostics.lastAdvanceIssue))")
                }
                if index >= warmupFrames { full.append(elapsed) }
                completed += 1; progress(completed, total)
                await Task.yield()
                if scenarioErrors > 0 { break }
            }
            if name == "semantic_spawn", !pendingSpawnCleanup.isEmpty {
                var cleanup = WorldTransaction()
                for id in pendingSpawnCleanup { cleanup = cleanup.remove(id) }
                world.submit(cleanup)
            } else if name == "merge", let lastMergeResultID {
                world.submit(WorldTransaction().remove(lastMergeResultID))
            }
            if name == "semantic_spawn" || name == "merge" {
                _ = await world.advance(by: 1.0 / 60)
                populationObserver?(name, world.renderState?.items.compactMap { $0 }.count ?? 0)
            }
            readbacks += world.benchmarkContourCPUReadbackCount
            func timing(_ values: [Double]) -> PublicWorldStressTiming {
                let sorted = values.sorted()
                let p95 = sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
                return PublicWorldStressTiming(p95Milliseconds: p95, maximumMilliseconds: sorted.last ?? .infinity)
            }
            reports.append(PublicWorldStressScenarioReport(name: name, warmupFrames: warmupFrames,
                measuredFrames: full.count, semanticInputFrames: semanticInputFrames,
                cpuInputToEncoding: timing(cpu), gpuCommandBuffer: timing(gpu),
                fullFrameInputToPresentation: timing(full)))
        }
        return PublicWorldStressReport(deviceName: device.name, scenarios: reports, solverIterationLimit: 4,
            guardCorrections: guardCorrections, nonFiniteFrames: nonFiniteFrames, fallbackFrames: fallbackFrames,
            commandBufferErrors: commandBufferErrors, overflowEvents: overflowEvents, contourCPUReadbacks: readbacks,
            diagnostics: diagnostics)
    }

    private static func makeConfiguration() throws -> WorldConfiguration {
        let region = try WorldRectangle(min: [0, 0], max: [375, 700])
        let arena = try ArenaPreset(id: "round", bounds: region, bubbleRadius: 12,
            physicsMaterialID: PhysicsMaterialID(rawValue: 1), renderStyleID: RenderStyleID(rawValue: 1))
        return try WorldConfiguration(simulationRegion: region, fixedTimeStep: 1.0 / 60, arenas: [arena])
    }
}

private final class DrawablePresentationLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var wasPresented = false

    func signal() {
        lock.lock()
        wasPresented = true
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if wasPresented {
                lock.unlock()
                continuation.resume()
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }
}

private enum StressBenchmarkError: Error { case metalUnavailable }
