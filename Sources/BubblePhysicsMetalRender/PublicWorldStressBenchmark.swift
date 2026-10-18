import BubblePhysics
import Metal
import Foundation

/// Wynik kompletnej ścieżki publicznego świata i bezpośredniego renderera.
public struct PublicWorldStressReport: Sendable {
    public let deviceName: String
    public let warmupFrames: Int
    public let measuredFrames: Int
    public let solverIterationLimit: Int
    public let p95Milliseconds: Double
    /// Czas GPU całego command buffera: solver, kontury i bezpośredni renderer.
    public let gpuP95Milliseconds: Double
    /// Część klatki poza czasem GPU, liczona na tej samej ukończonej próbce.
    public let hostNonGPUP95Milliseconds: Double
    /// Czas kodowania solvera i renderera po stronie hosta, bez oczekiwania na GPU.
    public let hostEncodingP95Milliseconds: Double
    /// Czas od commit do zakończenia tego samego command buffera.
    public let hostWaitingP95Milliseconds: Double
    public let maximumMilliseconds: Double
    public let guardCorrections: Int
    public let nonFiniteFrames: Int
    public let fallbackFrames: Int
    public let failedFrames: Int
    public let contourCPUReadbacks: Int

    /// Kontrola bezpieczeństwa; geometryczna obwiednia referencyjna wymaga osobnego porównania.
    public var safetyPassed: Bool {
        nonFiniteFrames == 0 && fallbackFrames == 0 && failedFrames == 0
            && contourCPUReadbacks == 0
    }

    public var text: String {
        """
        path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
        device=\(deviceName)
        scene=stress-300; solver_iteration_limit=\(solverIterationLimit)
        warmup=\(warmupFrames); measured=\(measuredFrames)
        p95_ms=\(String(format: "%.4f", p95Milliseconds)); max_ms=\(String(format: "%.4f", maximumMilliseconds))
        gpu_p95_ms=\(String(format: "%.4f", gpuP95Milliseconds)); host_non_gpu_p95_ms=\(String(format: "%.4f", hostNonGPUP95Milliseconds))
        host_encoding_p95_ms=\(String(format: "%.4f", hostEncodingP95Milliseconds)); host_waiting_p95_ms=\(String(format: "%.4f", hostWaitingP95Milliseconds))
        guard_corrections=\(guardCorrections); non_finite_frames=\(nonFiniteFrames)
        fallback_frames=\(fallbackFrames); failed_frames=\(failedFrames)
        contour_cpu_readbacks=\(contourCPUReadbacks)
        safety=\(safetyPassed ? "pass" : "fail")
        native_quality_envelope=not_evaluated_by_this_harness
        ceo_p95_gate_ms=10.4568; p95_gate=\(p95Milliseconds <= 10.4568 ? "pass" : "fail")
        """
    }
}

@MainActor
public enum PublicWorldStressBenchmark {
    /// Wymaga fizycznego urządzenia dla wyniku akceptacyjnego. Koduje oba etapy do jednego bufora.
    public static func measure(device: MTLDevice,
                               progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws
        -> PublicWorldStressReport {
        try await run(device: device, warmupFrames: 30, measuredFrames: 300, progress: progress)
    }

    package static func run(device: MTLDevice, warmupFrames: Int, measuredFrames: Int,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        let configuration = try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [0, 0], max: [375, 700]), fixedTimeStep: 1.0 / 60)
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
        var random = StressLCG(seed: 0x2B_60_F5)
        let horizontalSpacing: Float = 345 / 15
        let verticalSpacing: Float = 670 / 20
        let baseRadius = min(horizontalSpacing, verticalSpacing) * 0.54
        for index in 0..<300 {
            let column = index % 15, row = index / 15
            let jitterX = (random.nextUnit() - 0.5) * horizontalSpacing * 0.12
            let jitterY = (random.nextUnit() - 0.5) * verticalSpacing * 0.12
            let radius = baseRadius * (0.78 + random.nextUnit() * 0.44)
            transaction = transaction.add(.bubble(try BubbleDescriptor(
                id: ObjectID(rawValue: UInt64(index + 1)),
                position: [15 + (Float(column) + 0.5) * horizontalSpacing + jitterX,
                           15 + (Float(row) + 0.5) * verticalSpacing + jitterY],
                targetRadius: radius, mass: max(1, radius * radius * 0.02),
                physicsMaterialID: materialID, renderStyleID: styleID)))
        }
        let walls: [[WorldPoint]] = [
            [[0,0], [1,0], [1,700], [0,700]],
            [[374,0], [375,0], [375,700], [374,700]],
            [[0,0], [375,0], [375,1], [0,1]],
            [[0,699], [375,699], [375,700], [0,700]]
        ]
        for (index, vertices) in walls.enumerated() {
            transaction = transaction.add(.polygon(try PolygonDescriptor(
                id: ObjectID(rawValue: UInt64(10_001 + index)), vertices: vertices,
                physicsMaterialID: polygonMaterialID, renderStyleID: styleID)))
        }
        let triangleVertices: [WorldPoint] = [[-46,34], [46,34], [0,-52]]
        func triangle(step: Int) throws -> PolygonDescriptor {
            let waypoints: [WorldPoint] = [[187.5,350], [65,105], [310,595], [310,105], [65,595]]
            let leg = (step / 40) % waypoints.count
            let next = (leg + 1) % waypoints.count
            let t = Float(step % 40) / 40
            let center = WorldPoint(
                waypoints[leg].x + (waypoints[next].x - waypoints[leg].x) * t,
                waypoints[leg].y + (waypoints[next].y - waypoints[leg].y) * t)
            return try PolygonDescriptor(id: ObjectID(rawValue: 10_000), vertices: triangleVertices,
                position: center, physicsMaterialID: polygonMaterialID, renderStyleID: styleID)
        }
        transaction = transaction.add(.polygon(try triangle(step: 0)))
        world.submit(transaction)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 375, height: 700, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue() else { throw StressBenchmarkError.metalUnavailable }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        var measured: [Double] = []
        var gpuMeasured: [Double] = []
        var hostNonGPUMeasured: [Double] = []
        var hostEncodingMeasured: [Double] = []
        var hostWaitingMeasured: [Double] = []
        var guardCorrections = 0
        var nonFiniteFrames = 0
        var fallbackFrames = 0
        var failedFrames = 0
        let total = warmupFrames + measuredFrames
        for index in 0..<total {
            try Task.checkCancellation()
            if index > 0 {
                world.submit(WorldTransaction().replace(ObjectID(rawValue: 10_000),
                    with: .polygon(try triangle(step: index))))
            }
            guard let command = queue.makeCommandBuffer() else { throw StressBenchmarkError.metalUnavailable }
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
                try renderer.encode(world: world, viewport: Viewport(center: [187.5, 350], size: [375, 700]),
                    commandBuffer: command, renderPassDescriptor: pass)
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            if frame.stepIndex != UInt64(index + 1) || command.status != .completed
                || world.diagnostics.lastAdvanceIssue != nil { failedFrames += 1 }
            if let telemetry = world.benchmarkTelemetry {
                guardCorrections += telemetry.guardCorrectionCount
                if telemetry.didEncounterNonFinite { nonFiniteFrames += 1 }
                if telemetry.fallbackReason != nil { fallbackFrames += 1 }
                if index >= warmupFrames {
                    gpuMeasured.append(telemetry.gpuMilliseconds)
                    hostNonGPUMeasured.append(max(0, elapsed - telemetry.gpuMilliseconds))
                    if let profile = world.benchmarkFrameProfile {
                        hostEncodingMeasured.append(profile.hostEncodingMilliseconds)
                        hostWaitingMeasured.append(profile.hostWaitingMilliseconds)
                    } else { failedFrames += 1 }
                }
            } else { failedFrames += 1 }
            if index >= warmupFrames { measured.append(elapsed) }
            progress(index + 1, total)
            // BubbleWorld i renderer są celowo izolowane do MainActor. Bez tego
            // kooperacyjnego punktu SwiftUI nie może odmalować postępu ani
            // przyjąć żądania Stop między ukończonymi klatkami benchmarku.
            await Task.yield()
            if failedFrames > 0 { break }
        }
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1,
                Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        }
        measured.sort()
        let frameP95 = p95(measured)
        return PublicWorldStressReport(deviceName: device.name, warmupFrames: warmupFrames,
            measuredFrames: measured.count, solverIterationLimit: 4, p95Milliseconds: frameP95,
            gpuP95Milliseconds: p95(gpuMeasured), hostNonGPUP95Milliseconds: p95(hostNonGPUMeasured),
            hostEncodingP95Milliseconds: p95(hostEncodingMeasured),
            hostWaitingP95Milliseconds: p95(hostWaitingMeasured),
            maximumMilliseconds: measured.last ?? .infinity, guardCorrections: guardCorrections,
            nonFiniteFrames: nonFiniteFrames, fallbackFrames: fallbackFrames, failedFrames: failedFrames,
            contourCPUReadbacks: world.benchmarkContourCPUReadbackCount)
    }
}

private enum StressBenchmarkError: Error { case metalUnavailable }

private struct StressLCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}
