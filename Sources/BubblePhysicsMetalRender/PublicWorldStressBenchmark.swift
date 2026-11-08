import BubblePhysics
import Metal
import Foundation
import simd

/// Wynik kompletnej ścieżki publicznego świata i bezpośredniego renderera.
public struct PublicWorldStressReport: Sendable {
    /// Nazwa zmierzonej sceny: `stress-300` albo `mixed`.
    public let scene: String
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

    public var passesP95Gate: Bool { p95Milliseconds <= PublicWorldStressBenchmark.p95GateMilliseconds }

    public var text: String {
        """
        path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
        device=\(deviceName)
        scene=\(scene); solver_iteration_limit=\(solverIterationLimit)
        warmup=\(warmupFrames); measured=\(measuredFrames)
        p95_ms=\(String(format: "%.4f", p95Milliseconds)); max_ms=\(String(format: "%.4f", maximumMilliseconds))
        gpu_p95_ms=\(String(format: "%.4f", gpuP95Milliseconds)); host_non_gpu_p95_ms=\(String(format: "%.4f", hostNonGPUP95Milliseconds))
        host_encoding_p95_ms=\(String(format: "%.4f", hostEncodingP95Milliseconds)); host_waiting_p95_ms=\(String(format: "%.4f", hostWaitingP95Milliseconds))
        guard_corrections=\(guardCorrections); non_finite_frames=\(nonFiniteFrames)
        fallback_frames=\(fallbackFrames); failed_frames=\(failedFrames)
        contour_cpu_readbacks=\(contourCPUReadbacks)
        safety=\(safetyPassed ? "pass" : "fail")
        native_quality_envelope=not_evaluated_by_this_harness
        p95_gate_ms=\(String(format: "%.4f", PublicWorldStressBenchmark.p95GateMilliseconds)); p95_gate=\(passesP95Gate ? "pass" : "fail")
        """
    }
}

@MainActor
public enum PublicWorldStressBenchmark {
    /// Jedyne źródło progu akceptacji `stress-300` na iPhonie X (p95 pełnej klatki, limit solvera 4).
    /// Roboczy budżet to 10 ms; właściciel zaakceptował odchylenie 4,6% zmierzone 2026-10-14
    /// (docs/benchmarks/native-metal-bubble-solver-2026-10-14.md).
    public nonisolated static let p95GateMilliseconds = 10.4568

    /// Wymaga fizycznego urządzenia dla wyniku akceptacyjnego. Koduje oba etapy do jednego bufora.
    public static func measure(device: MTLDevice,
                               progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws
        -> PublicWorldStressReport {
        try await run(device: device, warmupFrames: 30, measuredFrames: 300, progress: progress)
    }

    /// Scena mierzona przez `run(scene:)`.
    package enum Scene: Equatable, Sendable {
        case stress(bubbleCount: Int)
        case mixed

        package static let stress300 = Scene.stress(bubbleCount: Stress300Scene.defaultBubbleCount)

        package var name: String {
            switch self {
            case .stress(let count): return count == Stress300Scene.defaultBubbleCount ? "stress-300" : "stress-\(count)"
            case .mixed: return "mixed"
            }
        }

        var regionHeight: Float {
            switch self {
            case .stress(let count): return Stress300Scene.regionHeight(bubbleCount: count)
            case .mixed: return MixedScene.regionHeight
            }
        }

        func configuration() throws -> WorldConfiguration {
            switch self {
            case .stress(let count): return try Stress300Scene.configuration(bubbleCount: count)
            case .mixed: return try MixedScene.configuration()
            }
        }

        func initialTransaction() throws -> WorldTransaction {
            switch self {
            case .stress(let count): return try Stress300Scene.initialTransaction(bubbleCount: count)
            case .mixed: return try MixedScene.initialTransaction()
            }
        }

        /// Transakcja przed krokiem `step` (numer od 0) albo `nil`, gdy scena nic wtedy nie zmienia.
        func stepTransaction(step: Int) throws -> WorldTransaction? {
            switch self {
            case .stress: return step > 0 ? try Stress300Scene.triangleReplacement(step: step) : nil
            case .mixed: return try MixedScene.stepTransaction(step: step)
            }
        }
    }

    package static func run(device: MTLDevice, bubbleCount: Int, warmupFrames: Int, measuredFrames: Int,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        try await run(device: device, scene: .stress(bubbleCount: bubbleCount), warmupFrames: warmupFrames,
                      measuredFrames: measuredFrames, progress: progress)
    }

    package static func run(device: MTLDevice, scene: Scene = .stress300,
                            warmupFrames: Int, measuredFrames: Int,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        let height = scene.regionHeight
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try scene.configuration(),
            device: device, solverIterationLimit: 4)
        let renderer = try BubblePhysicsMetalRender(device: device)
        world.submit(try scene.initialTransaction())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: 375, height: Int(height.rounded(.up)), mipmapped: false)
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
            if let transaction = try scene.stepTransaction(step: index) { world.submit(transaction) }
            guard let command = queue.makeCommandBuffer() else { throw StressBenchmarkError.metalUnavailable }
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
                try renderer.encode(world: world, viewport: Viewport(center: [187.5, height / 2], size: [375, height]),
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
        return PublicWorldStressReport(scene: scene.name, deviceName: device.name, warmupFrames: warmupFrames,
            measuredFrames: measured.count, solverIterationLimit: 4, p95Milliseconds: frameP95,
            gpuP95Milliseconds: p95(gpuMeasured), hostNonGPUP95Milliseconds: p95(hostNonGPUMeasured),
            hostEncodingP95Milliseconds: p95(hostEncodingMeasured),
            hostWaitingP95Milliseconds: p95(hostWaitingMeasured),
            maximumMilliseconds: measured.last ?? .infinity, guardCorrections: guardCorrections,
            nonFiniteFrames: nonFiniteFrames, fallbackFrames: fallbackFrames, failedFrames: failedFrames,
            contourCPUReadbacks: world.benchmarkContourCPUReadbackCount)
    }
}

/// Scena stress-300: 300 baniek, 4 ściany i kinematyczny trójkąt. Wspólna dla benchmarku, strażnika i testów.
/// `bubbleCount` skaluje scenę przy stałej gęstości (15 kolumn, region rośnie wzdłuż osi y), np. 600 dla skalowania.
package enum Stress300Scene {
    package static let defaultBubbleCount = 300
    private static let columns = 15

    /// Wysokość regionu: 700 dla 300 baniek (20 wierszy po 33,5 i 15 marginesu z obu stron).
    package static func regionHeight(bubbleCount: Int) -> Float {
        Float((bubbleCount + columns - 1) / columns) * 33.5 + 30
    }

    package static func configuration(bubbleCount: Int = defaultBubbleCount) throws -> WorldConfiguration {
        try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [0, 0], max: [375, regionHeight(bubbleCount: bubbleCount)]),
            fixedTimeStep: 1.0 / 60)
    }

    /// Materiały, 300 baniek, ściany i trójkąt w pozycji początkowej.
    package static func initialTransaction(bubbleCount: Int = defaultBubbleCount) throws -> WorldTransaction {
        let height = regionHeight(bubbleCount: bubbleCount)
        let materialID = PhysicsMaterialID(rawValue: 1)
        let polygonMaterialID = PhysicsMaterialID(rawValue: 2)
        let styleID = RenderStyleID(rawValue: 1)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(polygonMaterialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderStyle(styleID, style: try RenderStyle())
        var random = StressLCG(seed: 0x2B_60_F5)
        let horizontalSpacing: Float = 345 / 15
        let verticalSpacing: Float = 33.5
        let baseRadius = min(horizontalSpacing, verticalSpacing) * 0.54
        for index in 0..<bubbleCount {
            let column = index % columns, row = index / columns
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
            [[0,0], [1,0], [1,height], [0,height]],
            [[374,0], [375,0], [375,height], [374,height]],
            [[0,0], [375,0], [375,1], [0,1]],
            [[0,height - 1], [375,height - 1], [375,height], [0,height]]
        ]
        for (index, vertices) in walls.enumerated() {
            transaction = transaction.add(.rigidBody(try RigidBodyDescriptor(
                id: ObjectID(rawValue: UInt64(10_001 + index)), vertices: vertices,
                physicsMaterialID: polygonMaterialID, renderStyleID: styleID)))
        }
        transaction = transaction.add(.rigidBody(try triangle(step: 0)))
        return transaction
    }

    /// Zastępuje trójkąt jego pozycją na kroku `step` (tor po pięciu punktach, 40 kroków na odcinek).
    package static func triangleReplacement(step: Int) throws -> WorldTransaction {
        WorldTransaction().replace(ObjectID(rawValue: 10_000), with: .rigidBody(try triangle(step: step)))
    }

    private static func triangle(step: Int) throws -> RigidBodyDescriptor {
        let polygonMaterialID = PhysicsMaterialID(rawValue: 2)
        let styleID = RenderStyleID(rawValue: 1)
        let triangleVertices: [WorldPoint] = [[-46,34], [46,34], [0,-52]]
        let waypoints: [WorldPoint] = [[187.5,350], [65,105], [310,595], [310,105], [65,595]]
        let leg = (step / 40) % waypoints.count
        let next = (leg + 1) % waypoints.count
        let t = Float(step % 40) / 40
        let center = WorldPoint(
            waypoints[leg].x + (waypoints[next].x - waypoints[leg].x) * t,
            waypoints[leg].y + (waypoints[next].y - waypoints[leg].y) * t)
        return try RigidBodyDescriptor(id: ObjectID(rawValue: 10_000), vertices: triangleVertices,
            position: center, physicsMaterialID: polygonMaterialID, renderStyleID: styleID)
    }
}

/// Scena mieszana: 200 baniek, 60 brył (55 dynamicznych: wielokąty, koła, kapsuły i 5 kinematycznych belek),
/// 10 więzów i 4 ściany, bez grawitacji (jak stress-300); bryły startują z losową prędkością. Wspólna dla benchmarku, strażnika i testów.
/// Bańki leżą w dolnym pasie, dynamiczne bryły w siatce 11×5 nad belkami, belki przesuwają się poziomo.
package enum MixedScene {
    package static let bubbleCount = 200
    package static let regionHeight: Float = 700
    private static let bubbleColumns = 20
    private static let bodyColumns = 11
    private static let bodyRows = 5
    private static let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private static let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private static let style = RenderStyleID(rawValue: 1)
    private static let bubbleSpacing: Float = 345 / 20
    private static let bodySpacing: Float = 345 / 11
    private static let bodyRowY: [Float] = [450, 500, 550, 600, 650]
    private static let barY: [Float] = [210, 260, 310, 360, 410]
    /// Poniżej limitu materiału (90); półokres 150 kroków daje ten sam przejazd (200) co dawne 120 przez 100 kroków.
    private static let barSpeed: Float = 80
    private static let barHalfPeriod = 150

    package static func configuration() throws -> WorldConfiguration {
        try WorldConfiguration(simulationRegion: WorldRectangle(min: [0, 0], max: [375, regionHeight]),
                               fixedTimeStep: 1.0 / 60)
    }

    private static func bubbleID(_ index: Int) -> ObjectID { ObjectID(rawValue: UInt64(index + 1)) }
    private static func bodyID(_ index: Int) -> ObjectID { ObjectID(rawValue: UInt64(1_001 + index)) }
    private static func barID(_ index: Int) -> ObjectID { ObjectID(rawValue: UInt64(2_001 + index)) }

    private static func bubblePosition(_ index: Int) -> WorldPoint {
        [15 + (Float(index % bubbleColumns) + 0.5) * bubbleSpacing, 15 + (Float(index / bubbleColumns) + 0.5) * bubbleSpacing]
    }

    private static func bodyPosition(_ index: Int) -> WorldPoint {
        [15 + (Float(index % bodyColumns) + 0.5) * bodySpacing, bodyRowY[index / bodyColumns]]
    }

    package static func initialTransaction() throws -> WorldTransaction {
        var transaction = try WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(rigidMaterial, material: PhysicsMaterial(kind: .rigid, friction: 0.2, maximumLinearSpeed: 90, maximumAngularSpeed: 8))
            .updateRenderStyle(style, style: RenderStyle())
        var random = StressLCG(seed: 0x4D_1C_5E)
        for index in 0..<bubbleCount {
            let radius = bubbleSpacing * 0.4 * (0.78 + random.nextUnit() * 0.44)
            transaction = transaction.add(.bubble(try BubbleDescriptor(id: bubbleID(index), position: bubblePosition(index),
                targetRadius: radius, mass: max(1, radius * radius * 0.02),
                physicsMaterialID: bubbleMaterial, renderStyleID: style)))
        }
        for index in 0..<(bodyColumns * bodyRows) {
            transaction = transaction.add(.rigidBody(try dynamicBody(index, scale: 0.8 + random.nextUnit() * 0.4,
                velocity: [(random.nextUnit() - 0.5) * 80, (random.nextUnit() - 0.5) * 80],
                angularVelocity: (random.nextUnit() - 0.5) * 6)))
        }
        for index in 0..<barY.count {
            transaction = transaction.add(.rigidBody(try RigidBodyDescriptor(id: barID(index),
                vertices: [[-30, -4], [30, -4], [30, 4], [-30, 4]], position: [100, barY[index]], motionRole: .kinematic,
                physicsMaterialID: rigidMaterial, renderStyleID: style)))
            transaction = transaction.setKinematicDrive(barID(index), drive: .velocity(linear: [barSpeed, 0], angular: 0))
        }
        let walls: [[WorldPoint]] = [
            [[0, 0], [1, 0], [1, regionHeight], [0, regionHeight]],
            [[374, 0], [375, 0], [375, regionHeight], [374, regionHeight]],
            [[0, 0], [375, 0], [375, 1], [0, 1]],
            [[0, regionHeight - 1], [375, regionHeight - 1], [375, regionHeight], [0, regionHeight]]
        ]
        for (index, vertices) in walls.enumerated() {
            transaction = transaction.add(.rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: UInt64(10_001 + index)),
                vertices: vertices, physicsMaterialID: rigidMaterial, renderStyleID: style)))
        }
        for joint in try joints() { transaction = transaction.addJoint(joint) }
        return transaction
    }

    /// Cztery rodzaje brył na zmianę: prostokąt, koło, kapsuła, trójkąt. `scale` zmienia rozmiar o ±20%.
    private static func dynamicBody(_ index: Int, scale: Float, velocity: WorldPoint,
                                    angularVelocity: Float) throws -> RigidBodyDescriptor {
        let id = bodyID(index), position = bodyPosition(index)
        switch index % 4 {
        case 0:
            return try RigidBodyDescriptor(id: id, vertices: [[-9, -6], [9, -6], [9, 6], [-9, 6]].map { $0 * scale },
                position: position, velocity: velocity, angularVelocity: angularVelocity, motionRole: .dynamic,
                physicsMaterialID: rigidMaterial, renderStyleID: style)
        case 1:
            return try RigidBodyDescriptor(id: id, shape: .circle(radius: 8 * scale), position: position,
                velocity: velocity, angularVelocity: angularVelocity, motionRole: .dynamic, physicsMaterialID: rigidMaterial, renderStyleID: style)
        case 2:
            return try RigidBodyDescriptor(id: id, shape: .capsule(halfLength: 6 * scale, radius: 5 * scale),
                position: position, velocity: velocity, angularVelocity: angularVelocity, motionRole: .dynamic,
                physicsMaterialID: rigidMaterial, renderStyleID: style)
        default:
            return try RigidBodyDescriptor(id: id, vertices: [[-9, 7], [9, 7], [0, -9]].map { $0 * scale },
                position: position, velocity: velocity, angularVelocity: angularVelocity, motionRole: .dynamic,
                physicsMaterialID: rigidMaterial, renderStyleID: style)
        }
    }

    /// 10 więzów: 3 dystansowe i 2 zawiasy (jeden z zakresem, jeden z silnikiem) oraz spaw między sąsiednimi bryłami,
    /// 2 dystansowe bryła–świat, bańka–świat i bańka–bańka.
    private static func joints() throws -> [Joint] {
        var result: [Joint] = []
        var nextID: UInt64 = 1
        func make(_ build: (JointID) throws -> Joint) rethrows {
            result.append(try build(JointID(rawValue: nextID)))
            nextID += 1
        }
        let half = bodySpacing / 2
        for index in [0, 13, 24] {
            try make { try Joint(id: $0, bodyA: bodyID(index), bodyB: bodyID(index + 1),
                kind: .distance(length: bodySpacing, softness: 0, damping: 0)) }
        }
        try make { try Joint(id: $0, bodyA: bodyID(3), bodyB: bodyID(4), anchorA: [half, 0], anchorB: [-half, 0],
            kind: .hinge(limits: HingeLimits(lower: -0.8, upper: 0.8), motor: nil)) }
        try make { try Joint(id: $0, bodyA: bodyID(36), bodyB: bodyID(37), anchorA: [half, 0], anchorB: [-half, 0],
            kind: .hinge(limits: nil, motor: HingeMotor(targetAngularVelocity: 1, maximumTorque: 50))) }
        try make { try Joint(id: $0, bodyA: bodyID(6), bodyB: bodyID(7), anchorA: [half, 0], anchorB: [-half, 0], kind: .weld) }
        for index in [9, 31] {
            let top = bodyPosition(index) + [0, 60]
            try make { try Joint(id: $0, bodyA: bodyID(index), anchorB: top,
                kind: .distance(length: 60, softness: 0, damping: 0)) }
        }
        let held = bubblePosition(100)
        try make { try Joint(id: $0, bodyA: bubbleID(100), anchorB: held + [0, 30],
            kind: .distance(length: 30, softness: 0, damping: 0)) }
        let spacing = simd_distance(bubblePosition(55), bubblePosition(56))
        try make { try Joint(id: $0, bodyA: bubbleID(55), bodyB: bubbleID(56),
            kind: .distance(length: spacing, softness: 0, damping: 0)) }
        return result
    }

    /// Belki zawracają co `barHalfPeriod` kroków; poza tym scena nie zmienia się transakcjami.
    package static func stepTransaction(step: Int) throws -> WorldTransaction? {
        guard step > 0, step % barHalfPeriod == 0 else { return nil }
        let direction: Float = (step / barHalfPeriod) % 2 == 0 ? 1 : -1
        var transaction = WorldTransaction()
        for index in 0..<barY.count {
            transaction = transaction.setKinematicDrive(barID(index),
                drive: .velocity(linear: [direction * barSpeed, 0], angular: 0))
        }
        return transaction
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
