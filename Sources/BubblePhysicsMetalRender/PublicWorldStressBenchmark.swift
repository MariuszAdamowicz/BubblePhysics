import BubblePhysics
import BubblePhysicsAssets
import Metal
import CoreGraphics
import Foundation
import simd

/// Wynik kompletnej ścieżki publicznego świata i bezpośredniego renderera.
public struct PublicWorldStressReport: Sendable {
    /// Nazwa zmierzonej sceny: `stress-300`, `mixed`, `decals` albo `acceptance`.
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
    /// Czas od początku `advance` do początku kodowania solvera (przygotowanie wejścia kroku po stronie CPU).
    public let hostPreparationP95Milliseconds: Double
    /// Czas od zakończenia oczekiwania na GPU do powrotu z `advance` (odczyt, scalanie i publikacja kroku).
    public let hostPublicationP95Milliseconds: Double
    /// Czas GPU fizyki: druga seria na świeżym świecie tej samej sceny, z pustym `encodeRender`.
    public let gpuPhysicsP95Milliseconds: Double
    /// Szacunek kosztu renderu GPU: czas GPU klatki z renderem minus czas GPU fizyki.
    public var gpuRenderEstimateMilliseconds: Double { gpuP95Milliseconds - gpuPhysicsP95Milliseconds }
    public let maximumMilliseconds: Double
    public let guardCorrections: Int
    public let nonFiniteFrames: Int
    public let fallbackFrames: Int
    public let failedFrames: Int
    public let contourCPUReadbacks: Int
    /// Rozmiar celu renderu w pikselach.
    public let renderWidth: Int
    public let renderHeight: Int
    /// Suma kandydatów kontaktu odrzuconych przez limit wiersza w całym przebiegu; bezpieczna scena ma 0.
    public let contactCandidateOverflow: Int
    /// Największa liczba kandydatów kontaktu na jeden obiekt w którymkolwiek kroku przebiegu.
    public let maximumCandidatesPerObject: Int
    /// Limit kandydatów na obiekt (k); zapas wymaga `maximumCandidatesPerObject` ≤ k/2.
    public let candidateLimit: Int
    /// Próg p95 pełnej klatki dla zmierzonej sceny w milisekundach.
    public let gateMilliseconds: Double

    /// Kontrola bezpieczeństwa; geometryczna obwiednia referencyjna wymaga osobnego porównania.
    public var safetyPassed: Bool {
        nonFiniteFrames == 0 && fallbackFrames == 0 && failedFrames == 0
            && contourCPUReadbacks == 0
    }

    public var passesP95Gate: Bool { p95Milliseconds <= gateMilliseconds }

    public var text: String {
        """
        path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer
        device=\(deviceName)
        scene=\(scene); solver_iteration_limit=\(solverIterationLimit)
        render_px=\(renderWidth)x\(renderHeight)
        warmup=\(warmupFrames); measured=\(measuredFrames)
        p95_ms=\(String(format: "%.4f", p95Milliseconds)); max_ms=\(String(format: "%.4f", maximumMilliseconds))
        gpu_p95_ms=\(String(format: "%.4f", gpuP95Milliseconds)); host_non_gpu_p95_ms=\(String(format: "%.4f", hostNonGPUP95Milliseconds))
        host_preparation_p95_ms=\(String(format: "%.4f", hostPreparationP95Milliseconds)); host_publication_p95_ms=\(String(format: "%.4f", hostPublicationP95Milliseconds))
        host_encoding_p95_ms=\(String(format: "%.4f", hostEncodingP95Milliseconds)); host_waiting_p95_ms=\(String(format: "%.4f", hostWaitingP95Milliseconds))
        gpu_physics_p95_ms=\(String(format: "%.4f", gpuPhysicsP95Milliseconds)); gpu_render_estimate_ms=\(String(format: "%.4f", gpuRenderEstimateMilliseconds))
        guard_corrections=\(guardCorrections); non_finite_frames=\(nonFiniteFrames)
        fallback_frames=\(fallbackFrames); failed_frames=\(failedFrames)
        contour_cpu_readbacks=\(contourCPUReadbacks)
        contact_candidate_overflow=\(contactCandidateOverflow); max_candidates_per_object=\(maximumCandidatesPerObject); candidate_limit=\(candidateLimit)
        safety=\(safetyPassed ? "pass" : "fail")
        native_quality_envelope=not_evaluated_by_this_harness
        p95_gate_ms=\(String(format: "%.4f", gateMilliseconds)); p95_gate=\(passesP95Gate ? "pass" : "fail")
        """
    }
}

/// Próbka jednej klatki benchmarku dla testów: składowe czasu klatki w milisekundach.
package struct PublicWorldStressFrameSample {
    package enum Series: Equatable { case full, physicsOnly }
    package let series: Series
    /// Numer klatki w serii od 0, wliczając rozgrzewkę.
    package let index: Int
    package let frame: WorldFrame
    package let elapsedMilliseconds: Double
    package let preparationMilliseconds: Double
    package let encodingMilliseconds: Double
    package let waitingMilliseconds: Double
    package let publicationMilliseconds: Double
    package let gpuMilliseconds: Double
    /// Czy klatka wywołała `BubblePhysicsMetalRender.encode`.
    package let renderEncoded: Bool
    /// Znaczniki klatki w zegarze `DispatchTime.uptimeNanoseconds`: początek `advance`, początek kodowania,
    /// koniec oczekiwania na GPU i powrót z `advance`. Zera, gdy profil klatki był niedostępny.
    package let startNanoseconds: UInt64
    package let encodingStartNanoseconds: UInt64
    package let waitingEndNanoseconds: UInt64
    package let endNanoseconds: UInt64
}

@MainActor
public enum PublicWorldStressBenchmark {
    /// Jedyne źródło progu akceptacji `stress-300` na iPhonie X (p95 pełnej klatki, limit solvera 4).
    /// Roboczy budżet to 10 ms; właściciel zaakceptował odchylenie 4,6% zmierzone 2026-10-14
    /// (docs/benchmarks/native-metal-bubble-solver-2026-10-14.md).
    public nonisolated static let p95GateMilliseconds = 10.4568

    /// Próg p95 pełnej klatki sceny akceptacyjnej w natywnej rozdzielczości urządzenia: budżet 60 FPS.
    public nonisolated static let acceptanceGateMilliseconds = 16.67

    /// Wymaga fizycznego urządzenia dla wyniku akceptacyjnego. Koduje oba etapy do jednego bufora i renderuje poza ekranem
    /// w `renderSize` pikseli (`nil`: 375 × wysokość regionu sceny).
    public static func measure(device: MTLDevice, scene: Scene, renderSize: CGSize? = nil,
                               progress: @escaping @MainActor (Int, Int) -> Void = { _, _ in }) async throws
        -> PublicWorldStressReport {
        try await run(device: device, scene: scene, renderSize: renderSize, warmupFrames: 30, measuredFrames: 300,
                      progress: progress)
    }

    /// Scena mierzona przez `run(scene:)`.
    public enum Scene: Equatable, Sendable {
        case stress(bubbleCount: Int)
        case mixed
        /// stress-300 z teksturą przyklejoną i naklejką tekstową na każdej bańce; mierzy koszt naklejek i przycinania maską.
        case decals
        /// Scena akceptacyjna iPhone'a X: stress-300 z teksturą przyklejoną i naklejką tekstową, kinematycznym trójkątem
        /// z `KinematicDrive` i połową baniek na warstwie 1; oba materiały baniek mieszają alfą.
        case acceptance

        package static let stress300 = Scene.stress(bubbleCount: Stress300Scene.defaultBubbleCount)

        package var name: String {
            switch self {
            case .stress(let count): return count == Stress300Scene.defaultBubbleCount ? "stress-300" : "stress-\(count)"
            case .mixed: return "mixed"
            case .decals: return "decals"
            case .acceptance: return "acceptance"
            }
        }

        /// Próg p95 pełnej klatki sceny.
        package var gateMilliseconds: Double {
            self == .acceptance ? PublicWorldStressBenchmark.acceptanceGateMilliseconds : PublicWorldStressBenchmark.p95GateMilliseconds
        }

        var regionHeight: Float {
            switch self {
            case .stress(let count): return Stress300Scene.regionHeight(bubbleCount: count)
            case .mixed: return MixedScene.regionHeight
            case .decals, .acceptance: return Stress300Scene.regionHeight(bubbleCount: Stress300Scene.defaultBubbleCount)
            }
        }

        package func configuration() throws -> WorldConfiguration {
            switch self {
            case .stress(let count): return try Stress300Scene.configuration(bubbleCount: count)
            case .mixed: return try MixedScene.configuration()
            case .decals, .acceptance: return try Stress300Scene.configuration()
            }
        }

        /// Rejestry zasobów scena `decals` zapełnia przy tworzeniu transakcji (poza pomiarem).
        @MainActor package func initialTransaction(assets: AssetRegistry) throws -> WorldTransaction {
            switch self {
            case .stress(let count): return try Stress300Scene.initialTransaction(bubbleCount: count)
            case .mixed: return try MixedScene.initialTransaction()
            case .decals, .acceptance:
                let texture = try assets.register(Self.decalTextureImage())
                let font = try assets.register(font: "Helvetica-Bold", characters: "0123456789")
                return try Stress300Scene.initialTransaction(bubbleCount: Stress300Scene.defaultBubbleCount,
                    decorations: .init(texture: texture, font: font, acceptance: self == .acceptance))
            }
        }

        /// Gradient 64×64 z alfą 1: tekstura przyklejona do każdej bańki sceny `decals`.
        private static func decalTextureImage() throws -> CGImage {
            let side = 64
            var pixels = [UInt8](repeating: 255, count: side * side * 4)
            for row in 0..<side { for column in 0..<side {
                let offset = (row * side + column) * 4
                pixels[offset] = UInt8(80 + column * 175 / side); pixels[offset + 1] = UInt8(80 + row * 175 / side)
                pixels[offset + 2] = 160
            } }
            guard let provider = CGDataProvider(data: Data(pixels) as CFData), let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                      space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                      provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
            else { throw StressBenchmarkError.metalUnavailable }
            return image
        }

        /// Transakcja przed krokiem `step` (numer od 0) albo `nil`, gdy scena nic wtedy nie zmienia.
        package func stepTransaction(step: Int) throws -> WorldTransaction? {
            switch self {
            case .stress, .decals: return step > 0 ? try Stress300Scene.triangleReplacement(step: step) : nil
            // Trójkąt jedzie sam według `KinematicDrive` z transakcji początkowej.
            case .acceptance: return nil
            case .mixed: return try MixedScene.stepTransaction(step: step)
            }
        }
    }

    /// Piksele celu renderu: `nil` daje 375 × wysokość regionu; wymiary skończone, dodatnie i w granicach tekstury Metal.
    package static func pixelSize(_ renderSize: CGSize?, regionHeight: Float) throws -> (width: Int, height: Int) {
        guard let renderSize else { return (375, Int(regionHeight.rounded(.up))) }
        let limit = 16_384.0
        guard renderSize.width.isFinite, renderSize.height.isFinite,
              renderSize.width >= 1, renderSize.height >= 1,
              renderSize.width <= limit, renderSize.height <= limit else { throw StressBenchmarkError.invalidRenderSize }
        return (Int(renderSize.width), Int(renderSize.height))
    }

    package static func run(device: MTLDevice, bubbleCount: Int, warmupFrames: Int, measuredFrames: Int,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        try await run(device: device, scene: .stress(bubbleCount: bubbleCount), warmupFrames: warmupFrames,
                      measuredFrames: measuredFrames, progress: progress)
    }

    /// `renderSize` w pikselach celu renderu; `nil` daje 375 × wysokość regionu sceny. Viewport pokrywa region sceny
    /// w całości przy proporcjach celu, więc wynik w natywnej rozdzielczości nie jest rozciągnięty.
    /// `renderTargetObserver` dostaje cel renderu zaraz po utworzeniu (szew testowy: rozmiar zamiast pól raportu).
    package static func run(device: MTLDevice, scene: Scene = .stress300, renderSize: CGSize? = nil,
                            renderTargetObserver: ((MTLTexture) -> Void)? = nil,
                            frameObserver: ((PublicWorldStressFrameSample) -> Void)? = nil,
                            warmupFrames: Int, measuredFrames: Int,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        let height = scene.regionHeight
        let (pixelWidth, pixelHeight) = try pixelSize(renderSize, regionHeight: height)
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try scene.configuration(),
            device: device, solverIterationLimit: 4)
        guard let assets = world.assets else { throw StressBenchmarkError.metalUnavailable }
        let renderer = try BubblePhysicsMetalRender(device: device, assets: assets)
        world.submit(try scene.initialTransaction(assets: assets))
        let aspect = Float(pixelWidth) / Float(pixelHeight)
        let viewWidth = max(375, height * aspect)
        let viewport = try Viewport(center: [187.5, height / 2], size: [viewWidth, viewWidth / aspect])
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: pixelWidth, height: pixelHeight, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .private
        guard let texture = device.makeTexture(descriptor: descriptor),
              let queue = device.makeCommandQueue() else { throw StressBenchmarkError.metalUnavailable }
        renderTargetObserver?(texture)
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        pass.colorAttachments[0].storeAction = .store
        let total = warmupFrames + measuredFrames
        let full = try await runSeries(.full, world: world, scene: scene, queue: queue, warmupFrames: warmupFrames,
            totalFrames: total, observer: frameObserver, progress: { done, _ in progress(done, 2 * total) }) { command in
                try renderer.encode(world: world, viewport: viewport, commandBuffer: command, renderPassDescriptor: pass)
            }
        // Druga seria: świeży świat tej samej sceny, ta sama rozgrzewka i te same indeksy kroków, `encodeRender` pusty.
        // Fizyka obu serii jest identyczna, więc czas GPU drugiej to czas fizyki bez renderu.
        let physicsWorld = try BubbleWorld.makeBenchmarkWorld(configuration: try scene.configuration(),
            device: device, solverIterationLimit: 4)
        guard let physicsAssets = physicsWorld.assets else { throw StressBenchmarkError.metalUnavailable }
        physicsWorld.submit(try scene.initialTransaction(assets: physicsAssets))
        let physics = try await runSeries(.physicsOnly, world: physicsWorld, scene: scene, queue: queue,
            warmupFrames: warmupFrames, totalFrames: total, observer: frameObserver, progress: { done, _ in progress(total + done, 2 * total) },
            render: nil)
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1,
                Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        }
        let measured = full.frameMilliseconds.sorted()
        let frameP95 = p95(measured)
        return PublicWorldStressReport(scene: scene.name, deviceName: device.name, warmupFrames: warmupFrames,
            measuredFrames: measured.count, solverIterationLimit: 4, p95Milliseconds: frameP95,
            gpuP95Milliseconds: p95(full.gpuMilliseconds), hostNonGPUP95Milliseconds: p95(full.hostNonGPUMilliseconds),
            hostEncodingP95Milliseconds: p95(full.encodingMilliseconds),
            hostWaitingP95Milliseconds: p95(full.waitingMilliseconds),
            hostPreparationP95Milliseconds: p95(full.preparationMilliseconds),
            hostPublicationP95Milliseconds: p95(full.publicationMilliseconds),
            gpuPhysicsP95Milliseconds: p95(physics.gpuMilliseconds),
            maximumMilliseconds: measured.last ?? .infinity, guardCorrections: full.guardCorrections,
            nonFiniteFrames: full.nonFiniteFrames + physics.nonFiniteFrames,
            fallbackFrames: full.fallbackFrames + physics.fallbackFrames,
            failedFrames: full.failedFrames + physics.failedFrames,
            contourCPUReadbacks: world.benchmarkContourCPUReadbackCount + physicsWorld.benchmarkContourCPUReadbackCount,
            renderWidth: pixelWidth, renderHeight: pixelHeight,
            contactCandidateOverflow: world.diagnostics.contactCandidateOverflow,
            maximumCandidatesPerObject: full.maximumCandidates, candidateLimit: BubbleWorld.contactCandidateLimit,
            gateMilliseconds: scene.gateMilliseconds)
    }

    /// Zmierzone klatki jednej serii (bez rozgrzewki) i liczniki bezpieczeństwa całej serii.
    private struct SeriesResult {
        var frameMilliseconds: [Double] = []
        var gpuMilliseconds: [Double] = []
        var hostNonGPUMilliseconds: [Double] = []
        var preparationMilliseconds: [Double] = []
        var encodingMilliseconds: [Double] = []
        var waitingMilliseconds: [Double] = []
        var publicationMilliseconds: [Double] = []
        var guardCorrections = 0
        var nonFiniteFrames = 0
        var fallbackFrames = 0
        var failedFrames = 0
        var maximumCandidates = 0
    }

    /// Jedna seria `totalFrames` klatek na `world`: transakcja kroku, `advance` z jednym buforem i pomiar składowych.
    /// `render` nil to pusty `encodeRender` (seria fizyki bez renderu).
    /// Składowe dzielą klatkę bez dziur: przygotowanie (początek `advance` → początek kodowania), kodowanie, oczekiwanie
    /// na GPU i publikacja (koniec oczekiwania → powrót z `advance`), wszystkie w zegarze `DispatchTime.uptimeNanoseconds`.
    private static func runSeries(_ kind: PublicWorldStressFrameSample.Series, world: BubbleWorld, scene: Scene,
                                  queue: MTLCommandQueue, warmupFrames: Int, totalFrames: Int,
                                  observer: ((PublicWorldStressFrameSample) -> Void)?,
                                  progress: @escaping @MainActor (Int, Int) -> Void,
                                  render: ((MTLCommandBuffer) throws -> Void)?) async throws -> SeriesResult {
        var result = SeriesResult()
        for index in 0..<totalFrames {
            try Task.checkCancellation()
            if let transaction = try scene.stepTransaction(step: index) { world.submit(transaction) }
            guard let command = queue.makeCommandBuffer() else { throw StressBenchmarkError.metalUnavailable }
            var renderEncoded = false
            let start = DispatchTime.now().uptimeNanoseconds
            let frame = await world.advance(by: 1.0 / 60, commandBuffer: command) {
                if let render {
                    renderEncoded = true
                    try render(command)
                }
            }
            let end = DispatchTime.now().uptimeNanoseconds
            let elapsed = Double(end - start) / 1_000_000
            if frame.stepIndex != UInt64(index + 1) || command.status != .completed
                || world.diagnostics.lastAdvanceIssue != nil { result.failedFrames += 1 }
            var gpuMilliseconds = 0.0, preparation = 0.0, encoding = 0.0, waiting = 0.0, publication = 0.0
            var encodingStartMark: UInt64 = 0, waitingEndMark: UInt64 = 0
            if let telemetry = world.benchmarkTelemetry {
                result.guardCorrections += telemetry.guardCorrectionCount
                if telemetry.didEncounterNonFinite { result.nonFiniteFrames += 1 }
                if telemetry.fallbackReason != nil { result.fallbackFrames += 1 }
                gpuMilliseconds = telemetry.gpuMilliseconds
                if let profile = world.benchmarkFrameProfile,
                   profile.encodingStartNanoseconds >= start, profile.waitingEndNanoseconds >= profile.encodingStartNanoseconds,
                   end >= profile.waitingEndNanoseconds {
                    preparation = Double(profile.encodingStartNanoseconds - start) / 1_000_000
                    encoding = profile.hostEncodingMilliseconds
                    waiting = profile.hostWaitingMilliseconds
                    publication = Double(end - profile.waitingEndNanoseconds) / 1_000_000
                    encodingStartMark = profile.encodingStartNanoseconds
                    waitingEndMark = profile.waitingEndNanoseconds
                } else if index >= warmupFrames { result.failedFrames += 1 }
            } else { result.failedFrames += 1 }
            if index >= warmupFrames {
                result.gpuMilliseconds.append(gpuMilliseconds)
                result.hostNonGPUMilliseconds.append(max(0, elapsed - gpuMilliseconds))
                result.preparationMilliseconds.append(preparation)
                result.encodingMilliseconds.append(encoding)
                result.waitingMilliseconds.append(waiting)
                result.publicationMilliseconds.append(publication)
                result.frameMilliseconds.append(elapsed)
            }
            result.maximumCandidates = max(result.maximumCandidates, world.diagnostics.maximumContactCandidatesPerObject)
            observer?(PublicWorldStressFrameSample(series: kind, index: index, frame: frame, elapsedMilliseconds: elapsed,
                preparationMilliseconds: preparation, encodingMilliseconds: encoding, waitingMilliseconds: waiting,
                publicationMilliseconds: publication, gpuMilliseconds: gpuMilliseconds, renderEncoded: renderEncoded,
                startNanoseconds: start, encodingStartNanoseconds: encodingStartMark,
                waitingEndNanoseconds: waitingEndMark, endNanoseconds: end))
            progress(index + 1, totalFrames)
            // BubbleWorld i renderer są celowo izolowane do MainActor. Bez tego
            // kooperacyjnego punktu SwiftUI nie może odmalować postępu ani
            // przyjąć żądania Stop między ukończonymi klatkami benchmarku.
            await Task.yield()
            if result.failedFrames > 0 { break }
        }
        return result
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

    /// Zasoby sceny `decals`: tekstura przyklejona w materiale baniek i czcionka cyfr naklejek tekstowych.
    struct Decorations {
        let texture: TextureID
        let font: FontID
        /// Scena akceptacyjna: materiały alfa, połowa baniek na warstwie 1 i trójkąt kinematyczny z `KinematicDrive`.
        var acceptance = false
    }

    /// Materiały, 300 baniek, ściany i trójkąt w pozycji początkowej.
    package static func initialTransaction(bubbleCount: Int = defaultBubbleCount) throws -> WorldTransaction {
        try initialTransaction(bubbleCount: bubbleCount, decorations: nil)
    }

    /// To samo z `decorations`: materiał baniek ma teksturę w trybie przyklejonym, a każda bańka naklejkę tekstową (numer 0–99)
    /// czcionką z `decorations`.
    static func initialTransaction(bubbleCount: Int, decorations: Decorations?) throws -> WorldTransaction {
        let height = regionHeight(bubbleCount: bubbleCount)
        let acceptance = decorations?.acceptance == true
        let materialID = PhysicsMaterialID(rawValue: 1)
        let polygonMaterialID = PhysicsMaterialID(rawValue: 2)
        let styleID = RenderMaterialID(rawValue: 1)
        let upperStyleID = RenderMaterialID(rawValue: 2)
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble))
            .updatePhysicsMaterial(polygonMaterialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(styleID, material: try RenderMaterial(texture: decorations?.texture,
                color: acceptance ? RGBA(1, 1, 1, 0.9) : .white,
                blend: acceptance ? .alpha : .opaque, bubbleMapping: .attached))
        if acceptance {
            transaction = transaction.updateRenderMaterial(upperStyleID,
                material: try RenderMaterial(texture: decorations?.texture, color: RGBA(0.8, 0.9, 1, 0.7), blend: .alpha,
                                             bubbleMapping: .attached))
        }
        var random = StressLCG(seed: 0x2B_60_F5)
        let horizontalSpacing: Float = 345 / 15
        let verticalSpacing: Float = 33.5
        let baseRadius = min(horizontalSpacing, verticalSpacing) * 0.54
        for index in 0..<bubbleCount {
            let column = index % columns, row = index / columns
            let jitterX = (random.nextUnit() - 0.5) * horizontalSpacing * 0.12
            let jitterY = (random.nextUnit() - 0.5) * verticalSpacing * 0.12
            let radius = baseRadius * (0.78 + random.nextUnit() * 0.44)
            let upper = acceptance && index % 2 == 1
            transaction = transaction.add(.bubble(try BubbleDescriptor(
                id: ObjectID(rawValue: UInt64(index + 1)),
                position: [15 + (Float(column) + 0.5) * horizontalSpacing + jitterX,
                           15 + (Float(row) + 0.5) * verticalSpacing + jitterY],
                targetRadius: radius, mass: max(1, radius * radius * 0.02),
                physicsMaterialID: materialID, renderMaterialID: upper ? upperStyleID : styleID,
                layer: upper ? 1 : 0,
                decal: try decorations.map { try Decal.text(String(index % 100), source: .font($0.font)) })))
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
                physicsMaterialID: polygonMaterialID, renderMaterialID: styleID)))
        }
        transaction = transaction.add(.rigidBody(try triangle(step: 0, kinematic: acceptance)))
        if acceptance { transaction = transaction.setKinematicDrive(triangleID, drive: .path(try trianglePath())) }
        return transaction
    }

    /// Zastępuje trójkąt jego pozycją na kroku `step` (tor po pięciu punktach, 40 kroków na odcinek).
    package static func triangleReplacement(step: Int) throws -> WorldTransaction {
        WorldTransaction().replace(triangleID, with: .rigidBody(try triangle(step: step)))
    }

    private static let triangleID = ObjectID(rawValue: 10_000)
    private static let triangleWaypoints: [WorldPoint] = [[187.5,350], [65,105], [310,595], [310,105], [65,595]]

    /// Tor kinematycznego trójkąta sceny akceptacyjnej: te same punkty co w stress-300, dwa okrążenia, 200 jednostek na sekundę.
    private static func trianglePath() throws -> PathDrive {
        let lap = Array(triangleWaypoints.dropFirst()) + [triangleWaypoints[0]]
        return try PathDrive(points: lap + lap, speed: 200)
    }

    private static func triangle(step: Int, kinematic: Bool = false) throws -> RigidBodyDescriptor {
        let polygonMaterialID = PhysicsMaterialID(rawValue: 2)
        let styleID = RenderMaterialID(rawValue: 1)
        let triangleVertices: [WorldPoint] = [[-46,34], [46,34], [0,-52]]
        let waypoints = triangleWaypoints
        let leg = (step / 40) % waypoints.count
        let next = (leg + 1) % waypoints.count
        let t = Float(step % 40) / 40
        let center = WorldPoint(
            waypoints[leg].x + (waypoints[next].x - waypoints[leg].x) * t,
            waypoints[leg].y + (waypoints[next].y - waypoints[leg].y) * t)
        return try RigidBodyDescriptor(id: triangleID, vertices: triangleVertices,
            position: center, motionRole: kinematic ? .kinematic : .static, physicsMaterialID: polygonMaterialID, renderMaterialID: styleID)
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
    private static let style = RenderMaterialID(rawValue: 1)
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
            .updateRenderMaterial(style, material: try RenderMaterial())
        var random = StressLCG(seed: 0x4D_1C_5E)
        for index in 0..<bubbleCount {
            let radius = bubbleSpacing * 0.4 * (0.78 + random.nextUnit() * 0.44)
            transaction = transaction.add(.bubble(try BubbleDescriptor(id: bubbleID(index), position: bubblePosition(index),
                targetRadius: radius, mass: max(1, radius * radius * 0.02),
                physicsMaterialID: bubbleMaterial, renderMaterialID: style)))
        }
        for index in 0..<(bodyColumns * bodyRows) {
            transaction = transaction.add(.rigidBody(try dynamicBody(index, scale: 0.8 + random.nextUnit() * 0.4,
                velocity: [(random.nextUnit() - 0.5) * 80, (random.nextUnit() - 0.5) * 80],
                angularVelocity: (random.nextUnit() - 0.5) * 6)))
        }
        for index in 0..<barY.count {
            transaction = transaction.add(.rigidBody(try RigidBodyDescriptor(id: barID(index),
                vertices: [[-30, -4], [30, -4], [30, 4], [-30, 4]], position: [100, barY[index]], motionRole: .kinematic,
                physicsMaterialID: rigidMaterial, renderMaterialID: style)))
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
                vertices: vertices, physicsMaterialID: rigidMaterial, renderMaterialID: style)))
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
                physicsMaterialID: rigidMaterial, renderMaterialID: style)
        case 1:
            return try RigidBodyDescriptor(id: id, shape: .circle(radius: 8 * scale), position: position,
                velocity: velocity, angularVelocity: angularVelocity, motionRole: .dynamic, physicsMaterialID: rigidMaterial, renderMaterialID: style)
        case 2:
            return try RigidBodyDescriptor(id: id, shape: .capsule(halfLength: 6 * scale, radius: 5 * scale),
                position: position, velocity: velocity, angularVelocity: angularVelocity, motionRole: .dynamic,
                physicsMaterialID: rigidMaterial, renderMaterialID: style)
        default:
            return try RigidBodyDescriptor(id: id, vertices: [[-9, 7], [9, 7], [0, -9]].map { $0 * scale },
                position: position, velocity: velocity, angularVelocity: angularVelocity, motionRole: .dynamic,
                physicsMaterialID: rigidMaterial, renderMaterialID: style)
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

package enum StressBenchmarkError: Error {
    case metalUnavailable
    /// `renderSize` nie jest skończonym rozmiarem od 1 do 16384 pikseli w obu osiach.
    case invalidRenderSize
}

private struct StressLCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed == 0 ? 1 : seed }
    mutating func nextUnit() -> Float {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Float(state >> 40) / Float(1 << 24)
    }
}
