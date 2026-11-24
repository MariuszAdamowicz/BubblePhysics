import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import Metal
import CoreGraphics
import Foundation
import simd

/// Wynik kompletnej ścieżki publicznego świata i bezpośredniego renderera.
public struct PublicWorldStressReport: Sendable {
    /// Nazwa zmierzonej sceny: `stress-300`, `mixed`, `decals`, `acceptance` albo jedna z czterech scen G8-AC2
    /// (`resting-crowd`, `band-to-wall`, `head-on-128`, `shot-into-crowd`).
    public let scene: String
    public let deviceName: String
    public let warmupFrames: Int
    public let measuredFrames: Int
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
    /// Podkroki fizyki w klatkach mierzonych serii z renderem (`NativeMetalFrameTelemetry.substepCount`): p95 (nearest rank) i maksimum.
    public internal(set) var substepP95 = 0
    public internal(set) var substepMax = 0
    /// Histogram podkroków: liczba podkroków w klatce → liczba klatek mierzonych, które tyle miały.
    public internal(set) var substepHistogram: [Int: Int] = [:]
    /// Największa liczba przebudów siatki wymuszonych zapasem w jednej klatce mierzonej (`NativeMetalFrameTelemetry.gridRebuildCount`).
    public internal(set) var gridRebuildMax = 0
    /// Największa liczba par buforów podkroków w jednej klatce mierzonej (`NativeMetalFrameTelemetry.substepBufferCount`); 1 w jednej dyspozycji.
    public internal(set) var substepBuffersMax = 0
    /// Ścieżka wykonania z telemetrii klatek (`singleDispatch` albo `multipleDispatches`; `mixed`, gdy klatki serii różniły się ścieżką);
    /// `none`, gdy klatki nie miały telemetrii.
    public internal(set) var executionPath = "none"
    /// Szerokość grupy jądra pętli podkroków (`NativeMetalFrameTelemetry.singleGroupWidth`, największa z klatek); 0 w ścieżce wielu dyspozycji.
    public internal(set) var singleGroupWidth = 0
    /// Najdłuższa klatka mierzona serii z renderem w milisekundach (ta sama liczba co `max_ms`, pod nazwą z G8-AC2).
    public internal(set) var longestFrameMilliseconds = 0.0
    /// Czas GPU fizyki z telemetrii klatek serii z renderem: suma buforów podkroków, p95. Osobno od `gpuPhysicsP95Milliseconds`
    /// (druga seria bez renderu), który zasila prognozę iPhone'a X.
    public internal(set) var telemetryPhysicsGPUP95Milliseconds = 0.0
    /// Czas GPU konturu z telemetrii klatek serii z renderem: bufor końca kroku, p95.
    public internal(set) var telemetryContourGPUP95Milliseconds = 0.0
    /// Czekanie CPU na bufor renderu wywołującego (`BubbleWorld.benchmarkRenderWaitMilliseconds`), p95. To część
    /// `hostPublicationP95Milliseconds`, a nie osobny odcinek klatki.
    public internal(set) var hostRenderWaitP95Milliseconds = 0.0

    /// Szacunek kosztu renderu GPU: czas GPU klatki z renderem minus czas GPU fizyki.
    public var gpuRenderEstimateMilliseconds: Double { gpuP95Milliseconds - gpuPhysicsP95Milliseconds }
    /// Koszt samego czyszczenia celu renderu: czas GPU passa z samym czyszczeniem minus czas GPU fizyki (nie mniej niż 0).
    public internal(set) var gpuRenderClearEstimateMilliseconds: Double = 0
    /// Udział naklejek w renderze: czas GPU pełnego renderu minus czas GPU renderu bez naklejek (nie mniej niż 0).
    public internal(set) var gpuRenderDecalsEstimateMilliseconds: Double = 0
    /// Czy raport ma podział renderu (serie z samym czyszczeniem celu i bez naklejek); tylko scena akceptacyjna.
    package internal(set) var hasRenderSplit = false
    /// Liczba klatek obu serii, w których świat nie miał oczekiwanej liczby baniek (tylko poziomy trybu pojemności).
    public internal(set) var bubbleCountMismatchFrames = 0
    /// Czy każda seria przebiegu zebrała dokładnie `measuredFrames` klatek mierzonych (nieudana klatka ucina serię).
    package internal(set) var allSeriesComplete = true
    /// Najgorszy stan termiczny urządzenia z klatek mierzonych wszystkich serii.
    public internal(set) var worstThermalState: ProcessInfo.ThermalState = .nominal
    public let maximumMilliseconds: Double
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

    /// Linia podziału renderu z końcowym znakiem nowej linii albo pusty tekst, gdy scena nie mierzy podziału.
    private var renderSplitLine: String {
        hasRenderSplit
            ? "gpu_render_clear_estimate_ms=\(String(format: "%.4f", gpuRenderClearEstimateMilliseconds)); gpu_render_decals_estimate_ms=\(String(format: "%.4f", gpuRenderDecalsEstimateMilliseconds))\n"
            : ""
    }

    /// Histogram podkroków jako `przedział:klatki` oddzielone przecinkami, tylko niepuste przedziały rosnąco. Przedziały to potęgi
    /// dwójki: `1`, `2`, `3-4`, `5-8`, `9-16`, …
    package static func substepHistogramText(_ histogram: [Int: Int]) -> String {
        var buckets: [Int: Int] = [:]
        for (substeps, frames) in histogram where frames > 0 {
            var upper = 1
            while upper < substeps { upper *= 2 }
            buckets[upper, default: 0] += frames
        }
        return buckets.keys.sorted().map { upper in
            let label = upper == 1 ? "1" : upper == 2 ? "2" : "\(upper / 2 + 1)-\(upper)"
            return "\(label):\(buckets[upper] ?? 0)"
        }.joined(separator: ",")
    }

    public var text: String {
        """
        \(PublicWorldStressBenchmark.reportPathHeader)
        device=\(deviceName)
        scene=\(scene)
        render_px=\(renderWidth)x\(renderHeight)
        warmup=\(warmupFrames); measured=\(measuredFrames)
        p95_ms=\(String(format: "%.4f", p95Milliseconds)); max_ms=\(String(format: "%.4f", maximumMilliseconds))
        gpu_p95_ms=\(String(format: "%.4f", gpuP95Milliseconds)); host_non_gpu_p95_ms=\(String(format: "%.4f", hostNonGPUP95Milliseconds))
        host_preparation_p95_ms=\(String(format: "%.4f", hostPreparationP95Milliseconds)); host_publication_p95_ms=\(String(format: "%.4f", hostPublicationP95Milliseconds))
        host_encoding_p95_ms=\(String(format: "%.4f", hostEncodingP95Milliseconds)); host_waiting_p95_ms=\(String(format: "%.4f", hostWaitingP95Milliseconds))
        gpu_physics_p95_ms=\(String(format: "%.4f", gpuPhysicsP95Milliseconds)); gpu_render_estimate_ms=\(String(format: "%.4f", gpuRenderEstimateMilliseconds))
        substep_p95=\(substepP95); substep_max=\(substepMax); grid_rebuild_max=\(gridRebuildMax)
        substep_buffers_max=\(substepBuffersMax); execution_path=\(executionPath); single_group_width=\(singleGroupWidth)
        substep_histogram=\(Self.substepHistogramText(substepHistogram))
        longest_frame_ms=\(String(format: "%.4f", longestFrameMilliseconds)); host_render_wait_p95_ms=\(String(format: "%.4f", hostRenderWaitP95Milliseconds))
        telemetry_physics_gpu_p95_ms=\(String(format: "%.4f", telemetryPhysicsGPUP95Milliseconds)); telemetry_contour_gpu_p95_ms=\(String(format: "%.4f", telemetryContourGPUP95Milliseconds))
        \(renderSplitLine)non_finite_frames=\(nonFiniteFrames)
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
    package enum Series: Equatable { case full, physicsOnly, clearOnly, withoutDecals }
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
    /// Pola telemetrii natywnej klatki (`BubbleWorld.benchmarkTelemetry`; `nil`, gdy jej nie było) i czekanie CPU na bufor renderu
    /// (`BubbleWorld.benchmarkRenderWaitMilliseconds`).
    package let substepCount: Int?
    package let gridRebuildCount: Int?
    /// Pary buforów podkroków klatki, ścieżka wykonania (`singleDispatch` albo `multipleDispatches`) i szerokość grupy jądra pętli (G8-AC1, G8-AC4).
    package let substepBufferCount: Int?
    package let executionPath: String?
    package let singleGroupWidth: Int?
    package let physicsGPUMilliseconds: Double?
    package let contourGPUMilliseconds: Double?
    package let renderWaitMilliseconds: Double
    /// Znaczniki klatki w zegarze `DispatchTime.uptimeNanoseconds`: początek `advance`, początek kodowania,
    /// koniec oczekiwania na GPU i powrót z `advance`. Zera, gdy profil klatki był niedostępny.
    package let startNanoseconds: UInt64
    package let encodingStartNanoseconds: UInt64
    package let waitingEndNanoseconds: UInt64
    package let endNanoseconds: UInt64
}

@MainActor
public enum PublicWorldStressBenchmark {
    /// Jedyne źródło progu akceptacji `stress-300` na iPhonie X (p95 pełnej klatki).
    /// Roboczy budżet to 10 ms; właściciel zaakceptował odchylenie 4,6% zmierzone 2026-10-14
    /// (docs/benchmarks/native-metal-bubble-solver-2026-10-14.md).
    public nonisolated static let p95GateMilliseconds = 10.4568

    /// Próg p95 pełnej klatki sceny akceptacyjnej w natywnej rozdzielczości urządzenia: budżet 60 FPS.
    public nonisolated static let acceptanceGateMilliseconds = 16.67

    /// Pierwsza linia raportu `run` i raportu pojemności: ścieżka, którą mierzy benchmark.
    fileprivate nonisolated static let reportPathHeader = "path=public BubbleWorld + BubblePhysicsMetalRender, same command buffer"

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
        /// G8-AC2: 150 baniek w spoczynku w ramie ścian.
        case restingCrowd
        /// G8-AC2: bańka „2” ciągnięta gumką w pełnym naciągnięciu do ściany, obok tłum w spoczynku.
        case bandToWall
        /// G8-AC2: dwie bańki 128 lecące na siebie po 10³ j/s w osobnym pasie, obok tłum w spoczynku.
        case headOn128
        /// G8-AC2: bańka „2” wystrzelona 3 · 10³ j/s przez otwór ramy w tłum.
        case shotIntoCrowd

        package static let stress300 = Scene.stress(bubbleCount: Stress300Scene.defaultBubbleCount)

        package var name: String {
            switch self {
            case .stress(let count): return count == Stress300Scene.defaultBubbleCount ? "stress-300" : "stress-\(count)"
            case .mixed: return "mixed"
            case .decals: return "decals"
            case .acceptance: return "acceptance"
            case .restingCrowd: return "resting-crowd"
            case .bandToWall: return "band-to-wall"
            case .headOn128: return "head-on-128"
            case .shotIntoCrowd: return "shot-into-crowd"
            }
        }

        /// Próg p95 pełnej klatki sceny.
        package var gateMilliseconds: Double {
            switch self {
            case .acceptance, .restingCrowd, .bandToWall, .headOn128, .shotIntoCrowd:
                return PublicWorldStressBenchmark.acceptanceGateMilliseconds
            case .stress, .mixed, .decals: return PublicWorldStressBenchmark.p95GateMilliseconds
            }
        }

        var regionHeight: Float {
            switch self {
            case .stress(let count): return Stress300Scene.regionHeight(bubbleCount: count)
            case .mixed: return MixedScene.regionHeight
            case .decals, .acceptance: return Stress300Scene.regionHeight(bubbleCount: Stress300Scene.defaultBubbleCount)
            case .restingCrowd, .bandToWall, .headOn128, .shotIntoCrowd: return BudgetScenes.regionHeight
            }
        }

        package func configuration() throws -> WorldConfiguration {
            switch self {
            case .stress(let count): return try Stress300Scene.configuration(bubbleCount: count)
            case .mixed: return try MixedScene.configuration()
            case .decals, .acceptance: return try Stress300Scene.configuration()
            case .restingCrowd, .bandToWall, .headOn128, .shotIntoCrowd: return try BudgetScenes.configuration()
            }
        }

        /// Rejestry zasobów scena `decals` zapełnia przy tworzeniu transakcji (poza pomiarem).
        @MainActor package func initialTransaction(assets: AssetRegistry) throws -> WorldTransaction {
            switch self {
            case .stress(let count): return try Stress300Scene.initialTransaction(bubbleCount: count)
            case .mixed: return try MixedScene.initialTransaction()
            case .decals, .acceptance:
                return try Self.decoratedTransaction(assets: assets, bubbleCount: Stress300Scene.defaultBubbleCount,
                                                     acceptance: self == .acceptance)
            case .restingCrowd, .bandToWall, .headOn128, .shotIntoCrowd: return try BudgetScenes.initialTransaction(self)
            }
        }

        /// Scena `decals` albo akceptacyjna z `bubbleCount` bańkami: rejestruje teksturę i czcionkę i buduje transakcję początkową.
        @MainActor static func decoratedTransaction(assets: AssetRegistry, bubbleCount: Int,
                                                    acceptance: Bool) throws -> WorldTransaction {
            let texture = try assets.register(Self.decalTextureImage())
            let font = try assets.register(font: "Helvetica-Bold", characters: "0123456789")
            return try Stress300Scene.initialTransaction(bubbleCount: bubbleCount,
                decorations: .init(texture: texture, font: font, acceptance: acceptance))
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
            // Trójkąt jedzie sam według `KinematicDrive` z transakcji początkowej (bryła nie przeskakuje nad bańkami).
            case .stress, .decals, .acceptance, .restingCrowd, .bandToWall: return nil
            case .mixed: return try MixedScene.stepTransaction(step: step)
            case .headOn128, .shotIntoCrowd: return try BudgetScenes.stepTransaction(self, step: step)
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

    /// `run(device:spec:…)` dla jednej ze scen benchmarku, z podziałem renderu sceny akceptacyjnej.
    /// `renderSize` w pikselach celu renderu; `nil` daje 375 × wysokość regionu sceny.
    /// `renderTargetObserver` dostaje cel renderu zaraz po utworzeniu (szew testowy: rozmiar zamiast pól raportu).
    package static func run(device: MTLDevice, scene: Scene = .stress300, renderSize: CGSize? = nil,
                            renderTargetObserver: ((MTLTexture) -> Void)? = nil,
                            frameObserver: ((PublicWorldStressFrameSample) -> Void)? = nil,
                            warmupFrames: Int, measuredFrames: Int,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        try await run(device: device, spec: BenchmarkSceneSpec(scene), renderSize: renderSize,
                      renderTargetObserver: renderTargetObserver, frameObserver: frameObserver,
                      warmupFrames: warmupFrames, measuredFrames: measuredFrames, progress: progress)
    }

    /// Viewport pokrywa region sceny w całości przy proporcjach celu, więc wynik w natywnej rozdzielczości nie jest rozciągnięty.
    /// Cel renderu: `renderSize`, a bez niego rozmiar własny specyfikacji (poziom pojemności), a bez niego 375 × wysokość regionu.
    /// `renderSplit: false` pomija serie podziału renderu sceny akceptacyjnej (tryb pojemności).
    /// `thermalState` jest czytany raz po każdej klatce mierzonej każdej serii (nie w rozgrzewce); najgorszy stan trafia do raportu.
    package static func run(device: MTLDevice, spec: BenchmarkSceneSpec, renderSize: CGSize? = nil, renderSplit: Bool = true,
                            thermalState: () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
                            renderTargetObserver: ((MTLTexture) -> Void)? = nil,
                            frameObserver: ((PublicWorldStressFrameSample) -> Void)? = nil,
                            warmupFrames: Int, measuredFrames: Int,
                            progress: @escaping @MainActor (Int, Int) -> Void) async throws
        -> PublicWorldStressReport {
        let height = spec.regionHeight
        let (pixelWidth, pixelHeight) = try pixelSize(renderSize ?? spec.renderSize, regionHeight: height)
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try spec.configuration(),
            device: device)
        guard let assets = world.assets else { throw StressBenchmarkError.metalUnavailable }
        let renderer = try BubblePhysicsMetalRender(device: device, assets: assets)
        world.submit(try spec.initialTransaction(assets: assets))
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
        let splitsRender = renderSplit && spec.splitsRender
        let seriesCount = splitsRender ? 4 : 2
        let total = warmupFrames + measuredFrames
        func seriesProgress(_ number: Int) -> @MainActor (Int, Int) -> Void {
            { done, _ in progress(number * total + done, seriesCount * total) }
        }
        let full = try await runSeries(.full, world: world, spec: spec, queue: queue, warmupFrames: warmupFrames,
            totalFrames: total, thermalState: thermalState, observer: frameObserver, progress: seriesProgress(0)) { command in
                try renderer.encode(world: world, viewport: viewport, commandBuffer: command, renderPassDescriptor: pass)
            }
        // Druga seria: świeży świat tej samej sceny, ta sama rozgrzewka i te same indeksy kroków, `encodeRender` pusty.
        // Fizyka obu serii jest identyczna, więc czas GPU drugiej to czas fizyki bez renderu.
        let physicsWorld = try freshWorld(spec, device: device)
        let physics = try await runSeries(.physicsOnly, world: physicsWorld, spec: spec, queue: queue,
            warmupFrames: warmupFrames, totalFrames: total, thermalState: thermalState, observer: frameObserver,
            progress: seriesProgress(1), render: nil)
        // Podział renderu (tylko scena akceptacyjna): każda seria na świeżym świecie tej samej sceny, z tą samą rozgrzewką
        // i tymi samymi indeksami kroków, więc fizyka jest identyczna. Pass z samym czyszczeniem celu mierzy koszt, którego
        // nie da się zbić (prawdziwy drawable też musi być zapisany), a render bez naklejek odsłania udział naklejek.
        var clear: SeriesResult?, withoutDecals: SeriesResult?
        var splitWorlds: [BubbleWorld] = []
        if splitsRender {
            let clearWorld = try freshWorld(spec, device: device)
            clear = try await runSeries(.clearOnly, world: clearWorld, spec: spec, queue: queue,
                warmupFrames: warmupFrames, totalFrames: total, thermalState: thermalState, observer: frameObserver,
                progress: seriesProgress(2)) { command in
                    guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
                        throw BubblePhysicsMetalRenderError.renderEncoderUnavailable
                    }
                    encoder.label = "bubble-physics.benchmark-clear-only"
                    encoder.endEncoding()
                }
            let decalsWorld = try freshWorld(spec, device: device)
            guard let decalsAssets = decalsWorld.assets else { throw StressBenchmarkError.metalUnavailable }
            let decalsRenderer = try BubblePhysicsMetalRender(device: device, assets: decalsAssets)
            decalsRenderer.drawsDecals = false
            withoutDecals = try await runSeries(.withoutDecals, world: decalsWorld, spec: spec, queue: queue,
                warmupFrames: warmupFrames, totalFrames: total, thermalState: thermalState, observer: frameObserver,
                progress: seriesProgress(3)) { command in
                    try decalsRenderer.encode(world: decalsWorld, viewport: viewport, commandBuffer: command,
                                              renderPassDescriptor: pass)
                }
            splitWorlds = [clearWorld, decalsWorld]
        }
        func p95(_ values: [Double]) -> Double {
            let sorted = values.sorted()
            return sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1,
                Int(ceil(Double(sorted.count) * 0.95)) - 1)]
        }
        let measured = full.frameMilliseconds.sorted()
        let frameP95 = p95(measured)
        let extra = [clear, withoutDecals].compactMap { $0 }
        let allSeries = [full, physics] + extra
        var report = PublicWorldStressReport(scene: spec.name, deviceName: device.name, warmupFrames: warmupFrames,
            measuredFrames: measured.count, p95Milliseconds: frameP95,
            gpuP95Milliseconds: p95(full.gpuMilliseconds), hostNonGPUP95Milliseconds: p95(full.hostNonGPUMilliseconds),
            hostEncodingP95Milliseconds: p95(full.encodingMilliseconds),
            hostWaitingP95Milliseconds: p95(full.waitingMilliseconds),
            hostPreparationP95Milliseconds: p95(full.preparationMilliseconds),
            hostPublicationP95Milliseconds: p95(full.publicationMilliseconds),
            gpuPhysicsP95Milliseconds: p95(physics.gpuMilliseconds),
            maximumMilliseconds: measured.last ?? .infinity,
            nonFiniteFrames: allSeries.reduce(0) { $0 + $1.nonFiniteFrames },
            fallbackFrames: allSeries.reduce(0) { $0 + $1.fallbackFrames },
            failedFrames: allSeries.reduce(0) { $0 + $1.failedFrames },
            contourCPUReadbacks: ([world, physicsWorld] + splitWorlds).reduce(0) { $0 + $1.benchmarkContourCPUReadbackCount },
            renderWidth: pixelWidth, renderHeight: pixelHeight,
            contactCandidateOverflow: ([world, physicsWorld] + splitWorlds).reduce(0) { $0 + $1.diagnostics.contactCandidateOverflow },
            maximumCandidatesPerObject: allSeries.map(\.maximumCandidates).max() ?? 0,
            candidateLimit: BubbleWorld.contactCandidateLimit, gateMilliseconds: spec.gateMilliseconds)
        // Klucze G8-AC1/G8-AC2 z telemetrii klatek mierzonych serii z renderem.
        let substeps = full.substepCounts.sorted()
        report.substepMax = substeps.last ?? 0
        report.substepP95 = substeps.isEmpty ? 0 : Int(p95(substeps.map(Double.init)))
        report.substepHistogram = Dictionary(full.substepCounts.map { ($0, 1) }, uniquingKeysWith: +)
        report.gridRebuildMax = full.gridRebuildCounts.max() ?? 0
        report.substepBuffersMax = full.substepBufferCounts.max() ?? 0
        // Ścieżka z klatek: wspólna wartość, a gdy klatki się różnią (świat przekroczył próg w trakcie serii), `mixed`.
        let paths = Set(full.executionPaths)
        report.executionPath = paths.count == 1 ? paths.first! : (paths.isEmpty ? "none" : "mixed")
        report.singleGroupWidth = full.singleGroupWidths.max() ?? 0
        report.longestFrameMilliseconds = measured.last ?? 0
        report.telemetryPhysicsGPUP95Milliseconds = full.physicsGPUMilliseconds.isEmpty ? 0 : p95(full.physicsGPUMilliseconds)
        report.telemetryContourGPUP95Milliseconds = full.contourGPUMilliseconds.isEmpty ? 0 : p95(full.contourGPUMilliseconds)
        report.hostRenderWaitP95Milliseconds = full.renderWaitMilliseconds.isEmpty ? 0 : p95(full.renderWaitMilliseconds)
        report.bubbleCountMismatchFrames = allSeries.reduce(0) { $0 + $1.bubbleCountMismatchFrames }
        report.allSeriesComplete = allSeries.allSatisfy { $0.frameMilliseconds.count == measuredFrames }
        report.worstThermalState = allSeries.map(\.worstThermalState).max { $0.rawValue < $1.rawValue } ?? .nominal
        if let clear, let withoutDecals {
            report.hasRenderSplit = true
            report.gpuRenderClearEstimateMilliseconds = max(0, p95(clear.gpuMilliseconds) - p95(physics.gpuMilliseconds))
            report.gpuRenderDecalsEstimateMilliseconds = max(0, p95(full.gpuMilliseconds) - p95(withoutDecals.gpuMilliseconds))
        }
        return report
    }

    /// Pomiar pojemności: poziomy 100–400 baniek co 50 sceny akceptacyjnej w stałej skali, każdy po 30 klatkach rozgrzewki
    /// i 300 mierzonych (seria z renderem i seria bez renderu), z czekaniem na `nominal` przed każdym poziomem
    /// (najdłużej 10 minut) i stanem termicznym z klatek mierzonych w raporcie. Wymaga fizycznego urządzenia dla wyniku akceptacyjnego.
    public static func measureCapacity(device: MTLDevice,
                                       progress: @escaping @MainActor (PublicWorldCapacityProgress) -> Void = { _ in }) async throws
        -> PublicWorldCapacityReport {
        try await measureCapacity(device: device, levels: Array(stride(from: 100, through: 400, by: 50)),
                                  warmupFrames: 30, measuredFrames: 300,
                                  thermalState: { ProcessInfo.processInfo.thermalState },
                                  clock: .system, cooldownLimit: 600, progress: progress)
    }

    /// Wariant ze wstrzykniętymi poziomami, liczbą klatek, stanem termicznym, zegarem i limitem czekania (szew testów).
    /// Stan termiczny jest czytany przy czekaniu przed poziomem, a potem raz po każdej klatce mierzonej obu serii.
    package static func measureCapacity(device: MTLDevice, levels counts: [Int], warmupFrames: Int, measuredFrames: Int,
                                        thermalState: () -> ProcessInfo.ThermalState, clock: CooldownClock,
                                        cooldownLimit: Double,
                                        progress: @escaping @MainActor (PublicWorldCapacityProgress) -> Void = { _ in }) async throws
        -> PublicWorldCapacityReport {
        var levels: [PublicWorldCapacityReport.Level] = []
        for (index, count) in counts.enumerated() {
            try Task.checkCancellation()
            func event(_ phase: PublicWorldCapacityProgress.Phase) -> PublicWorldCapacityProgress {
                PublicWorldCapacityProgress(bubbleCount: count, levelIndex: index, levelCount: counts.count, phase: phase)
            }
            let cooldown = try await ThermalCooldown.wait(thermalState: thermalState, clock: clock, limit: cooldownLimit) {
                progress(event(.cooldown(seconds: $0, thermalState: $1)))
            }
            let report = try await run(device: device, spec: .capacity(bubbleCount: count), renderSplit: false,
                thermalState: thermalState, warmupFrames: warmupFrames, measuredFrames: measuredFrames) { done, total in
                    progress(event(.measuring(done: done, total: total)))
                }
            levels.append(PublicWorldCapacityReport.Level(report, bubbleCount: count, cooldownSeconds: cooldown.seconds,
                                                          cooldownTimedOut: cooldown.timedOut))
        }
        return PublicWorldCapacityReport(deviceName: device.name, warmupFrames: warmupFrames,
                                         measuredFrames: measuredFrames, levels: levels)
    }
    /// Świeży świat tej samej sceny z transakcją początkową, dla serii na identycznej fizyce.
    private static func freshWorld(_ spec: BenchmarkSceneSpec, device: MTLDevice) throws -> BubbleWorld {
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: try spec.configuration(),
            device: device)
        guard let assets = world.assets else { throw StressBenchmarkError.metalUnavailable }
        world.submit(try spec.initialTransaction(assets: assets))
        return world
    }

    private static func bubbleCount(of frame: WorldFrame) -> Int {
        frame.objects.values.reduce(0) { count, state in
            if case .bubble = state.kind { return count + 1 }
            return count
        }
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
        /// Telemetria klatek mierzonych (`benchmarkTelemetry`): podkroki, przebudowy siatki i czasy GPU fizyki i konturu; klatka bez
        /// telemetrii liczy się już jako nieudana, więc tu jej nie ma.
        var substepCounts: [Int] = []
        var gridRebuildCounts: [Int] = []
        var substepBufferCounts: [Int] = []
        var executionPaths: [String] = []
        var singleGroupWidths: [Int] = []
        var physicsGPUMilliseconds: [Double] = []
        var contourGPUMilliseconds: [Double] = []
        var renderWaitMilliseconds: [Double] = []
        var nonFiniteFrames = 0
        var fallbackFrames = 0
        var failedFrames = 0
        var maximumCandidates = 0
        /// Klatki (także rozgrzewki), w których liczba baniek świata różniła się od oczekiwanej przez specyfikację.
        var bubbleCountMismatchFrames = 0
        /// Najgorszy stan termiczny z klatek mierzonych serii.
        var worstThermalState = ProcessInfo.ThermalState.nominal
    }

    /// Jedna seria `totalFrames` klatek na `world`: transakcja kroku, `advance` z jednym buforem i pomiar składowych.
    /// `render` nil to pusty `encodeRender` (seria fizyki bez renderu).
    /// Składowe dzielą klatkę bez dziur: przygotowanie (początek `advance` → początek kodowania), kodowanie, oczekiwanie
    /// na GPU i publikacja (koniec oczekiwania → powrót z `advance`), wszystkie w zegarze `DispatchTime.uptimeNanoseconds`.
    private static func runSeries(_ kind: PublicWorldStressFrameSample.Series, world: BubbleWorld, spec: BenchmarkSceneSpec,
                                  queue: MTLCommandQueue, warmupFrames: Int, totalFrames: Int,
                                  thermalState: () -> ProcessInfo.ThermalState,
                                  observer: ((PublicWorldStressFrameSample) -> Void)?,
                                  progress: @escaping @MainActor (Int, Int) -> Void,
                                  render: ((MTLCommandBuffer) throws -> Void)?) async throws -> SeriesResult {
        var result = SeriesResult()
        for index in 0..<totalFrames {
            try Task.checkCancellation()
            if let transaction = try spec.stepTransaction(step: index) { world.submit(transaction) }
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
            let telemetry = world.benchmarkTelemetry
            if let telemetry {
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
            if let expected = spec.expectedBubbleCount, bubbleCount(of: frame) != expected {
                result.bubbleCountMismatchFrames += 1
            }
            if index >= warmupFrames {
                let state = thermalState()
                if state.rawValue > result.worstThermalState.rawValue { result.worstThermalState = state }
                result.gpuMilliseconds.append(gpuMilliseconds)
                result.hostNonGPUMilliseconds.append(max(0, elapsed - gpuMilliseconds))
                result.preparationMilliseconds.append(preparation)
                result.encodingMilliseconds.append(encoding)
                result.waitingMilliseconds.append(waiting)
                result.publicationMilliseconds.append(publication)
                if let telemetry {
                    result.substepCounts.append(telemetry.substepCount)
                    result.gridRebuildCounts.append(telemetry.gridRebuildCount)
                    result.substepBufferCounts.append(telemetry.substepBufferCount)
                    result.executionPaths.append(telemetry.executionPath.rawValue)
                    result.singleGroupWidths.append(telemetry.singleGroupWidth)
                    result.physicsGPUMilliseconds.append(telemetry.physicsGPUMilliseconds)
                    result.contourGPUMilliseconds.append(telemetry.contourGPUMilliseconds)
                }
                result.renderWaitMilliseconds.append(world.benchmarkRenderWaitMilliseconds)
                result.frameMilliseconds.append(elapsed)
            }
            result.maximumCandidates = max(result.maximumCandidates, world.diagnostics.maximumContactCandidatesPerObject)
            observer?(PublicWorldStressFrameSample(series: kind, index: index, frame: frame, elapsedMilliseconds: elapsed,
                preparationMilliseconds: preparation, encodingMilliseconds: encoding, waitingMilliseconds: waiting,
                publicationMilliseconds: publication, gpuMilliseconds: gpuMilliseconds, renderEncoded: renderEncoded,
                substepCount: telemetry?.substepCount, gridRebuildCount: telemetry?.gridRebuildCount,
                substepBufferCount: telemetry?.substepBufferCount, executionPath: telemetry?.executionPath.rawValue,
                singleGroupWidth: telemetry?.singleGroupWidth,
                physicsGPUMilliseconds: telemetry?.physicsGPUMilliseconds, contourGPUMilliseconds: telemetry?.contourGPUMilliseconds,
                renderWaitMilliseconds: world.benchmarkRenderWaitMilliseconds,
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

/// Scena stress-300: 300 baniek, 4 ściany i kinematyczny trójkąt z torem (`PathDrive`). Wspólna dla benchmarku, strażnika i testów.
/// `bubbleCount` skaluje scenę przy stałej gęstości (15 kolumn, region rośnie wzdłuż osi y), np. 600 dla skalowania.
/// Bańki leżą na siatce, a trójkąt startuje w jej środku: w 4.0.0 bryła nie może stanąć nad środkiem bańki (G7-AC1), więc
/// miejsca siatki w obrysie startowym trójkąta (z zapasem na promień bańki) zostają puste, a pozostałe bańki leżą jak dotąd.
package enum Stress300Scene {
    package static let defaultBubbleCount = 300
    private static let columns = 15
    /// K_c baniek sceny: start gry (229), czyli prawo kontaktu z granicą na promieniu w skali, którą zobaczy gracz.
    package static let bubbleContactStiffness: Float = 229

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
        /// Scena akceptacyjna: materiały alfa i połowa baniek na warstwie 1.
        var acceptance = false
    }

    /// Jedno miejsce siatki: numer bańki (od 0), środek i promień po losowaniu z jednego ciągu (ten sam co przy pełnej siatce).
    private struct Slot {
        let index: Int
        let position: WorldPoint
        let radius: Float
    }

    private static func slots(bubbleCount: Int) -> [Slot] {
        var random = StressLCG(seed: 0x2B_60_F5)
        let horizontalSpacing: Float = 345 / 15
        let verticalSpacing: Float = 33.5
        let baseRadius = min(horizontalSpacing, verticalSpacing) * 0.54
        let start = triangleWaypoints(regionHeight: regionHeight(bubbleCount: bubbleCount))[0]
        return (0..<bubbleCount).compactMap { index in
            let column = index % columns, row = index / columns
            let jitterX = (random.nextUnit() - 0.5) * horizontalSpacing * 0.12
            let jitterY = (random.nextUnit() - 0.5) * verticalSpacing * 0.12
            let radius = baseRadius * (0.78 + random.nextUnit() * 0.44)
            let position: WorldPoint = [15 + (Float(column) + 0.5) * horizontalSpacing + jitterX,
                                        15 + (Float(row) + 0.5) * verticalSpacing + jitterY]
            // Zapas to największy możliwy promień bańki sceny (baseRadius · 1,22) z odstępem.
            return distanceToTriangle(position, center: start) > baseRadius * 1.22 + 1 ? Slot(index: index, position: position, radius: radius) : nil
        }
    }

    /// Liczba baniek, które scena naprawdę tworzy: miejsca siatki poza obrysem startowym trójkąta.
    package static func placedBubbleCount(bubbleCount: Int = defaultBubbleCount) -> Int {
        slots(bubbleCount: bubbleCount).count
    }

    /// Materiały, 300 baniek (bez miejsc w obrysie trójkąta), ściany i trójkąt w pozycji początkowej z torem.
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
            .updatePhysicsMaterial(materialID, material: try PhysicsMaterial(kind: .bubble, contactStiffness: bubbleContactStiffness))
            .updatePhysicsMaterial(polygonMaterialID, material: try PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(styleID, material: try RenderMaterial(texture: decorations?.texture,
                color: acceptance ? RGBA(1, 1, 1, 0.9) : .white,
                blend: acceptance ? .alpha : .opaque, bubbleMapping: .attached))
        if acceptance {
            transaction = transaction.updateRenderMaterial(upperStyleID,
                material: try RenderMaterial(texture: decorations?.texture, color: RGBA(0.8, 0.9, 1, 0.7), blend: .alpha,
                                             bubbleMapping: .attached))
        }
        for slot in slots(bubbleCount: bubbleCount) {
            let upper = acceptance && slot.index % 2 == 1
            transaction = transaction.add(.bubble(try BubbleDescriptor(
                id: ObjectID(rawValue: UInt64(slot.index + 1)), position: slot.position,
                targetRadius: slot.radius, mass: max(1, slot.radius * slot.radius * 0.02),
                physicsMaterialID: materialID, renderMaterialID: upper ? upperStyleID : styleID,
                layer: upper ? 1 : 0,
                decal: try decorations.map { try Decal.text(String(slot.index % 100), source: .font($0.font)) })))
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
        // Tor trójkąta jest odwzorowany w osi y na wysokość regionu (poziomy pojemności); dla 300 baniek to punkty bez zmian.
        transaction = transaction.add(.rigidBody(try triangle(regionHeight: height)))
        transaction = transaction.setKinematicDrive(triangleID, drive: .path(try trianglePath(regionHeight: height)))
        return transaction
    }

    private static let triangleID = ObjectID(rawValue: 10_000)
    private static let waypoints700: [WorldPoint] = [[187.5,350], [65,105], [310,595], [310,105], [65,595]]
    /// Wysokość regionu sceny 300 baniek, dla której podano `waypoints700`.
    private static let referenceRegionHeight: Float = 700
    private static let triangleVertices: [WorldPoint] = [[-46,34], [46,34], [0,-52]]

    /// Punkty toru odwzorowane afinicznie w osi y na region o wysokości `regionHeight`:
    /// y′ = 105 + (y − 105)·(H − 210)/490, więc obwiednia trójkąta ma na całym torze te same odstępy od dolnej (53)
    /// i górnej (71) krawędzi co przy H = 700, gdzie punkty zostają bez zmian.
    private static func triangleWaypoints(regionHeight: Float) -> [WorldPoint] {
        guard regionHeight != referenceRegionHeight else { return waypoints700 }
        let scale = (regionHeight - 210) / 490
        return waypoints700.map { WorldPoint($0.x, 105 + ($0.y - 105) * scale) }
    }

    /// Tor kinematycznego trójkąta: te same punkty co w stress-300, dwa okrążenia, 200 jednostek na sekundę.
    private static func trianglePath(regionHeight: Float) throws -> PathDrive {
        let points = triangleWaypoints(regionHeight: regionHeight)
        let lap = Array(points.dropFirst()) + [points[0]]
        return try PathDrive(points: lap + lap, speed: 200)
    }

    private static func triangle(regionHeight: Float) throws -> RigidBodyDescriptor {
        try RigidBodyDescriptor(id: triangleID, vertices: triangleVertices,
            position: triangleWaypoints(regionHeight: regionHeight)[0], motionRole: .kinematic,
            physicsMaterialID: PhysicsMaterialID(rawValue: 2), renderMaterialID: RenderMaterialID(rawValue: 1))
    }

    /// Odległość punktu od trójkąta o środku `center` (0 w środku): obrys startowy bryły.
    private static func distanceToTriangle(_ point: WorldPoint, center: WorldPoint) -> Float {
        let corners = triangleVertices.map { $0 + center }
        func cross(_ a: WorldPoint, _ b: WorldPoint) -> Float { a.x * b.y - a.y * b.x }
        let signs = (0..<3).map { cross(corners[($0 + 1) % 3] - corners[$0], point - corners[$0]) }
        if signs.allSatisfy({ $0 >= 0 }) || signs.allSatisfy({ $0 <= 0 }) { return 0 }
        return (0..<3).map { edge -> Float in
            let a = corners[edge], b = corners[(edge + 1) % 3]
            let t = max(0, min(1, simd_dot(point - a, b - a) / simd_dot(b - a, b - a)))
            return simd_distance(point, a + (b - a) * t)
        }.min() ?? 0
    }
}

/// Cztery sceny G8-AC2, po 150 baniek, wszystkie w regionie 375 × 700 z jednym materiałem baniek (K_c gry, γ = 1) i bryłami tylko
/// statycznymi. Tłum to bańki r 12 (m 0,36) na siatce z nakładaniem 0,5 j (ściśnięty tłum, który leży w spoczynku).
/// - `restingCrowd`: 150 baniek tłumu w ramie ścian.
/// - `bandToWall`: 149 baniek tłumu nad poziomą ścianą i bańka „2” (r 24, m 1) w pasie pod nią, ciągnięta gumką gry (K_band 22) do celu
///   o 900 j za pionową ścianą. „2” startuje w spoczynku w położeniu równowagi (d* z prawa kontaktu dla siły gumki K_band · s,
///   ok. 3 j od ściany, siła ok. 1,3 · 10⁴), więc w całej rozgrzewce i w klatkach mierzonych stoi dociśnięta napiętą gumką.
/// - `headOn128`: 148 baniek tłumu pod poziomą ścianą i dwie bańki 128 (r 64) w osobnym pasie nad nią, lecące na siebie po 10³ j/s.
/// - `shotIntoCrowd`: 149 baniek tłumu w ramie ścian z otworem w lewej ścianie i bańka „2” startująca poza ramą (w pasie przy lewej
///   ścianie regionu), wystrzelona 3 · 10³ j/s przez otwór w tłum.
/// Sceny uderzeń (`headOn128`, `shotIntoCrowd`) powtarzają uderzenie co 20 klatek transakcją `.replace` uczestników z pozycją i
/// prędkością początkową, więc uderzenia są też w części mierzonej, a nie tylko w rozgrzewce.
fileprivate enum BudgetScenes {
    static let bubbleCount = 150
    static let regionHeight: Float = 700
    /// Co ile klatek sceny uderzeń wznawiają uderzenie.
    static let impactInterval = 20
    static let headOnSpeed: Float = 1_000
    static let shotSpeed: Float = 3_000

    private static let width: Float = 375
    private static let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    private static let rigidMaterial = PhysicsMaterialID(rawValue: 2)
    private static let style = RenderMaterialID(rawValue: 1)
    private static let crowdRadius: Float = 12
    private static let crowdMass: Float = 0.36
    private static let crowdSpacing: Float = 23.5
    private static let bandStiffness: Float = 22
    /// Masa gry m = (n / 2)^(1 / 2,25): „2” ma 1, 128 ma ok. 6,35.
    private static let mass128: Float = pow(64, 1 / 2.25)

    static func configuration() throws -> WorldConfiguration {
        try WorldConfiguration(simulationRegion: WorldRectangle(min: [0, 0], max: [width, regionHeight]), fixedTimeStep: 1.0 / 60)
    }

    /// Bańka spoza tłumu: „2” albo 128, z prędkością początkową i polityką gumki (tylko `bandToWall`).
    private struct Participant {
        let id: ObjectID
        let position: WorldPoint
        let velocity: WorldPoint
        let radius: Float
        let mass: Float
        var drivePolicy: BubbleDrivePolicy?

        func object() throws -> WorldObject {
            .bubble(try BubbleDescriptor(id: id, position: position, velocity: velocity, targetRadius: radius, mass: mass,
                                         physicsMaterialID: BudgetScenes.bubbleMaterial, renderMaterialID: BudgetScenes.style,
                                         drivePolicy: drivePolicy))
        }
    }

    private static func participants(_ scene: PublicWorldStressBenchmark.Scene) throws -> [Participant] {
        switch scene {
        case .bandToWall:
            return [Participant(id: ObjectID(rawValue: 150), position: [bandRestX, bandY], velocity: .zero, radius: 24, mass: 1,
                                drivePolicy: try BubbleDrivePolicy(bandStiffness: bandStiffness))]
        case .headOn128:
            return [Participant(id: ObjectID(rawValue: 149), position: [80, 585], velocity: [headOnSpeed, 0], radius: 64, mass: mass128),
                    Participant(id: ObjectID(rawValue: 150), position: [295, 585], velocity: [-headOnSpeed, 0], radius: 64, mass: mass128)]
        case .shotIntoCrowd:
            return [Participant(id: ObjectID(rawValue: 150), position: [30, 365], velocity: [shotSpeed, 0], radius: 24, mass: 1)]
        default:
            return []
        }
    }

    /// Cel gumki `bandToWall`: 900 j za pionową ścianą, w osi pasu (y = `bandY`).
    private static let bandY: Float = 100
    private static let bandTarget: WorldPoint = [900, bandY]
    /// Lewa powierzchnia pionowej ściany sceny `bandToWall` (prostokąt 10_006).
    private static let bandWallX: Float = 330
    private static let bandRadius: Float = 24

    /// Położenie środka „2” w równowadze z gumką: siła F = K_band · (cel − x) równoważy kontakt ze ścianą, czyli
    /// d = r · (1 − ε), gdzie ε / (1 − ε)² = F / K_c (prawo kontaktu 4.0.0; ε = 2q / ((2q + 1) + √(4q + 1)) dla q = F / K_c).
    /// Odległość d zależy od x tylko przez siłę gumki, więc kilka iteracji punktu stałego zbiega do float.
    private static var bandRestX: Float {
        var x = Double(bandWallX - bandRadius)
        for _ in 0..<50 {
            let force = Double(bandStiffness) * (Double(bandTarget.x) - x)
            let q = force / Double(Stress300Scene.bubbleContactStiffness)
            let epsilon = 2 * q / ((2 * q + 1) + (4 * q + 1).squareRoot())
            x = Double(bandWallX) - Double(bandRadius) * (1 - epsilon)
        }
        return Float(x)
    }

    /// `count` miejsc siatki o kroku `crowdSpacing` w pasie x ∈ [minX, maxX], wyśrodkowanej w poziomie i w pionie względem `centerY`.
    private static func crowdPositions(count: Int, minX: Float, maxX: Float, centerY: Float) -> [WorldPoint] {
        let columns = Int((maxX - minX) / crowdSpacing)
        let rows = (count + columns - 1) / columns
        let x0 = minX + (maxX - minX - Float(columns) * crowdSpacing) / 2 + crowdSpacing / 2
        let y0 = centerY - Float(rows - 1) * crowdSpacing / 2
        return (0..<count).map { [x0 + Float($0 % columns) * crowdSpacing, y0 + Float($0 / columns) * crowdSpacing] }
    }

    private static func crowd(_ scene: PublicWorldStressBenchmark.Scene, count: Int) -> [WorldPoint] {
        switch scene {
        case .bandToWall: return crowdPositions(count: count, minX: 1, maxX: 374, centerY: 450)
        case .headOn128: return crowdPositions(count: count, minX: 1, maxX: 374, centerY: 235)
        case .shotIntoCrowd: return crowdPositions(count: count, minX: 61, maxX: 374, centerY: 365)
        default: return crowdPositions(count: count, minX: 1, maxX: 374, centerY: 350)
        }
    }

    private static func rectangle(_ id: UInt64, _ low: WorldPoint, _ high: WorldPoint) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: id),
            vertices: [low, [high.x, low.y], high, [low.x, high.y]],
            physicsMaterialID: rigidMaterial, renderMaterialID: style))
    }

    /// Cztery ściany regionu i ściany wewnętrzne sceny (poziome przegrody, ściana oporowa, rama z otworem).
    private static func walls(_ scene: PublicWorldStressBenchmark.Scene) throws -> [WorldObject] {
        var walls = [try rectangle(10_001, [0, 0], [1, regionHeight]), try rectangle(10_002, [374, 0], [375, regionHeight]),
                     try rectangle(10_003, [0, 0], [375, 1]), try rectangle(10_004, [0, regionHeight - 1], [375, regionHeight])]
        switch scene {
        case .bandToWall:
            walls += [try rectangle(10_005, [1, 200], [374, 201]), try rectangle(10_006, [330, 1], [331, 200])]
        case .headOn128:
            walls += [try rectangle(10_005, [1, 470], [374, 471])]
        case .shotIntoCrowd:
            // Rama tłumu: lewa ściana na x = 60 z otworem y ∈ [330, 400] (średnica „2” 48, otwór 70).
            walls += [try rectangle(10_005, [60, 1], [61, 330]), try rectangle(10_006, [60, 400], [61, regionHeight - 1])]
        default:
            break
        }
        return walls
    }

    static func initialTransaction(_ scene: PublicWorldStressBenchmark.Scene) throws -> WorldTransaction {
        var transaction = try WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble, contactStiffness: Stress300Scene.bubbleContactStiffness, damping: 1))
            .updatePhysicsMaterial(rigidMaterial, material: PhysicsMaterial(kind: .rigid))
            .updateRenderMaterial(style, material: RenderMaterial())
        let extra = try participants(scene)
        for (index, position) in crowd(scene, count: bubbleCount - extra.count).enumerated() {
            transaction = transaction.add(.bubble(try BubbleDescriptor(id: ObjectID(rawValue: UInt64(index + 1)), position: position,
                targetRadius: crowdRadius, mass: crowdMass, physicsMaterialID: bubbleMaterial, renderMaterialID: style)))
        }
        for participant in extra { transaction = transaction.add(try participant.object()) }
        for wall in try walls(scene) { transaction = transaction.add(wall) }
        if scene == .bandToWall, let band = extra.first { transaction = transaction.beginPlayerDrive(band.id, target: bandTarget) }
        return transaction
    }

    /// Co `impactInterval` klatek (od drugiej serii, bo krok 0 ma jeszcze stan początkowy) `.replace` uczestników uderzenia.
    static func stepTransaction(_ scene: PublicWorldStressBenchmark.Scene, step: Int) throws -> WorldTransaction? {
        guard scene == .headOn128 || scene == .shotIntoCrowd, step > 0, step % impactInterval == 0 else { return nil }
        var transaction = WorldTransaction()
        for participant in try participants(scene) { transaction = transaction.replace(participant.id, with: try participant.object()) }
        return transaction
    }
}

/// Scena mieszana: 200 baniek, 60 brył kinematycznych (55 obracających się w miejscu: wielokąty, koła, kapsuły i 5 belek
/// przesuwających się poziomo) i 4 ściany, bez grawitacji (jak stress-300). Wspólna dla benchmarku, strażnika i testów.
/// W 4.0.0 świat z bańkami nie ma brył dynamicznych ani przegubów z bańkami (CD-D-2), więc bryły są kinematyczne;
/// sceny brył dynamicznych są osobne (testy brył bez baniek).
/// Bańki leżą w dolnym pasie, obracające się bryły w siatce 11×5 nad belkami, belki przesuwają się poziomo.
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
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble, contactStiffness: Stress300Scene.bubbleContactStiffness))
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
            let scale = 0.8 + random.nextUnit() * 0.4
            // Dwa losowania prędkości liniowej zostają w ciągu, żeby rozmiary i obroty były te same co przy dawnej scenie.
            _ = random.nextUnit(); _ = random.nextUnit()
            let angularVelocity = (random.nextUnit() - 0.5) * 6
            transaction = transaction.add(.rigidBody(try spinningBody(index, scale: scale)))
                .setKinematicDrive(bodyID(index), drive: .velocity(linear: .zero, angular: angularVelocity))
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
        return transaction
    }

    /// Cztery rodzaje brył na zmianę: prostokąt, koło, kapsuła, trójkąt. `scale` zmienia rozmiar o ±20%.
    private static func spinningBody(_ index: Int, scale: Float) throws -> RigidBodyDescriptor {
        let id = bodyID(index), position = bodyPosition(index)
        switch index % 4 {
        case 0:
            return try RigidBodyDescriptor(id: id, vertices: [[-9, -6], [9, -6], [9, 6], [-9, 6]].map { $0 * scale },
                position: position, motionRole: .kinematic,
                physicsMaterialID: rigidMaterial, renderMaterialID: style)
        case 1:
            return try RigidBodyDescriptor(id: id, shape: .circle(radius: 8 * scale), position: position,
                motionRole: .kinematic, physicsMaterialID: rigidMaterial, renderMaterialID: style)
        case 2:
            return try RigidBodyDescriptor(id: id, shape: .capsule(halfLength: 6 * scale, radius: 5 * scale),
                position: position, motionRole: .kinematic,
                physicsMaterialID: rigidMaterial, renderMaterialID: style)
        default:
            return try RigidBodyDescriptor(id: id, vertices: [[-9, 7], [9, 7], [0, -9]].map { $0 * scale },
                position: position, motionRole: .kinematic,
                physicsMaterialID: rigidMaterial, renderMaterialID: style)
        }
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

/// Specyfikacja sceny benchmarku: jedna ze scen `Scene` albo poziom trybu pojemności (scena akceptacyjna z n bańkami).
/// `run(device:scene:…)` buduje ją z `Scene`, a tryb pojemności z liczby baniek.
package struct BenchmarkSceneSpec {
    private enum Kind {
        case scene(PublicWorldStressBenchmark.Scene)
        case capacity(bubbleCount: Int)
    }
    private let kind: Kind
    /// Transakcje kroków podstawiane przez test za transakcję sceny, gdy zwrócą wartość (szew testowy, np. usunięcie bańki).
    private var extraStepTransaction: ((Int) -> WorldTransaction?)?

    package init(_ scene: PublicWorldStressBenchmark.Scene) { kind = .scene(scene) }

    /// Poziom pojemności: obszar 375 × H, H = ⌈n/15⌉·33,5 + 30, ten sam generator baniek (pierwsze n miejsc siatki jak na każdym
    /// poziomie, bez miejsc w obrysie startowym trójkąta), teksturą i naklejką tekstową na każdej bańce, dwiema warstwami z materiałem alfa i kinematycznym trójkątem
    /// z torem odwzorowanym w osi y. Poziom 300 daje te same operacje co `Scene.acceptance`.
    package static func capacity(bubbleCount: Int) -> BenchmarkSceneSpec {
        BenchmarkSceneSpec(kind: .capacity(bubbleCount: bubbleCount))
    }

    private init(kind: Kind) { self.kind = kind }

    /// Specyfikacja, w której krok `step` dostaje transakcję zwróconą przez `hook` zamiast transakcji sceny, o ile jest (szew testowy).
    package func addingStepTransaction(_ hook: @escaping (Int) -> WorldTransaction?) -> BenchmarkSceneSpec {
        var copy = self
        copy.extraStepTransaction = hook
        return copy
    }

    package var name: String {
        switch kind {
        case .scene(let scene): return scene.name
        case .capacity(let count): return "capacity-\(count)"
        }
    }

    /// Próg p95 pełnej klatki.
    package var gateMilliseconds: Double {
        switch kind {
        case .scene(let scene): return scene.gateMilliseconds
        case .capacity: return PublicWorldStressBenchmark.acceptanceGateMilliseconds
        }
    }

    package var regionHeight: Float {
        switch kind {
        case .scene(let scene): return scene.regionHeight
        case .capacity(let count): return Stress300Scene.regionHeight(bubbleCount: count)
        }
    }

    /// Własny cel renderu specyfikacji w pikselach: 1125 × ⌊2436·H/700⌋ (stała skala sceny 300) albo `nil`.
    package var renderSize: CGSize? {
        switch kind {
        case .scene: return nil
        case .capacity: return CGSize(width: 1125, height: (2436.0 * Double(regionHeight) / 700).rounded(.down))
        }
    }

    /// Czy scena ma serie podziału renderu (tylko scena akceptacyjna).
    package var splitsRender: Bool {
        if case .scene(.acceptance) = kind { return true }
        return false
    }

    /// Liczba baniek, którą świat ma mieć w każdej klatce, albo `nil`, gdy scena jej nie pilnuje.
    package var expectedBubbleCount: Int? {
        if case .capacity(let count) = kind { return Stress300Scene.placedBubbleCount(bubbleCount: count) }
        return nil
    }

    package func configuration() throws -> WorldConfiguration {
        switch kind {
        case .scene(let scene): return try scene.configuration()
        case .capacity(let count): return try Stress300Scene.configuration(bubbleCount: count)
        }
    }

    @MainActor package func initialTransaction(assets: AssetRegistry) throws -> WorldTransaction {
        switch kind {
        case .scene(let scene): return try scene.initialTransaction(assets: assets)
        case .capacity(let count):
            return try PublicWorldStressBenchmark.Scene.decoratedTransaction(assets: assets, bubbleCount: count, acceptance: true)
        }
    }

    package func stepTransaction(step: Int) throws -> WorldTransaction? {
        let base: WorldTransaction?
        switch kind {
        case .scene(let scene): base = try scene.stepTransaction(step: step)
        // Trójkąt jedzie sam według `KinematicDrive` z transakcji początkowej.
        case .capacity: base = nil
        }
        return extraStepTransaction?(step) ?? base
    }
}

/// Zegar czekania na schłodzenie: czas w sekundach i uśpienie; wstrzykiwany w testach.
package struct CooldownClock {
    package var now: () -> Double
    package var sleep: (Double) async throws -> Void

    package init(now: @escaping () -> Double, sleep: @escaping (Double) async throws -> Void) {
        self.now = now
        self.sleep = sleep
    }

    /// Zegar systemu: monotoniczny czas pracy i `Task.sleep`.
    package static let system = CooldownClock(
        now: { ProcessInfo.processInfo.systemUptime },
        sleep: { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) })
}

/// Czekanie na stan termiczny `nominal` przed poziomem pojemności.
@MainActor package enum ThermalCooldown {
    /// Co ile sekund sprawdzany jest stan termiczny podczas czekania.
    package static let pollIntervalSeconds = 5.0

    /// Czeka, aż `thermalState` zwróci `nominal`, najdłużej `limit` sekund. Zwraca czas czekania i to, czy limit minął
    /// (wtedy poziom jest mierzony mimo to). Stan jest czytany przed każdym uśpieniem, więc `nominal` od początku nie czeka wcale.
    /// `onPoll` dostaje czas dotychczasowego czekania i stan z każdego czytania.
    package static func wait(thermalState: () -> ProcessInfo.ThermalState, clock: CooldownClock, limit: Double,
                             onPoll: (Double, ProcessInfo.ThermalState) -> Void = { _, _ in }) async throws
        -> (seconds: Double, timedOut: Bool) {
        let start = clock.now()
        while true {
            let state = thermalState()
            let elapsed = clock.now() - start
            onPoll(elapsed, state)
            if state == .nominal { return (elapsed, false) }
            if elapsed >= limit { return (elapsed, true) }
            try await clock.sleep(min(pollIntervalSeconds, limit - elapsed))
        }
    }
}

extension ProcessInfo.ThermalState {
    /// Nazwa stanu w raporcie pojemności.
    fileprivate var capacityReportName: String {
        switch self {
        case .nominal: return "nominal"
        case .fair: return "fair"
        case .serious: return "serious"
        case .critical: return "critical"
        @unknown default: return "critical"
        }
    }
}

/// Postęp trybu pojemności: poziom, czekanie na schłodzenie albo pomiar.
public struct PublicWorldCapacityProgress: Sendable {
    public enum Phase: Sendable {
        /// Czekanie na `nominal`: dotychczasowy czas czekania w sekundach i ostatnio odczytany stan.
        case cooldown(seconds: Double, thermalState: ProcessInfo.ThermalState)
        /// Pomiar poziomu: ukończone klatki ze wszystkich serii poziomu (z rozgrzewką).
        case measuring(done: Int, total: Int)
    }

    /// Liczba baniek mierzonego poziomu.
    public let bubbleCount: Int
    /// Numer poziomu od 0 i liczba poziomów.
    public let levelIndex: Int
    public let levelCount: Int
    public let phase: Phase
}

/// Wynik trybu pojemności: jedna linia na poziom i pojemność wg reguły z G12-AC4.
public struct PublicWorldCapacityReport: Sendable {
    /// Wynik jednego poziomu: liczniki sumują obie serie (z renderem i bez renderu).
    public struct Level: Sendable {
        public let bubbleCount: Int
        /// Czas czekania na `nominal` przed poziomem w sekundach.
        public let cooldownSeconds: Double
        /// Czy czekanie przekroczyło limit i poziom zmierzono mimo to.
        public let cooldownTimedOut: Bool
        /// Najgorszy stan termiczny z klatek mierzonych obu serii.
        public let thermalWorst: ProcessInfo.ThermalState
        public let p95Milliseconds: Double
        public let hostNonGPUP95Milliseconds: Double
        public let gpuPhysicsP95Milliseconds: Double
        public let gpuRenderEstimateMilliseconds: Double
        public let maximumCandidatesPerObject: Int
        public let candidateLimit: Int
        public let failedFrames: Int
        public let nonFiniteFrames: Int
        public let contourCPUReadbacks: Int
        public let contactCandidateOverflow: Int
        /// Czy w każdej klatce obu serii świat miał dokładnie `bubbleCount` baniek.
        public let bubblesMatchedInEveryFrame: Bool
        /// Czy obie serie zebrały pełną liczbę klatek mierzonych (seria ucięta nieudaną klatką liczy p95 z krótszej próbki).
        /// Nie ma własnego pola w linii `level=`: ucięcie serii dziś zawsze towarzyszy `failed_frames > 0`.
        public let measuredFramesComplete: Bool

        /// Poziom jest ważny, gdy najgorszy stan termiczny to `nominal` albo `fair` oraz spełnione są zera poprawności
        /// (CD-D-30): brak nieudanych klatek, klatek z wartościami nieskończonymi, odczytów konturów i przepełnień
        /// kandydatów kontaktu, n baniek w każdej klatce i pełna liczba klatek mierzonych w obu seriach.
        public var isValid: Bool {
            (thermalWorst == .nominal || thermalWorst == .fair)
                && failedFrames == 0 && nonFiniteFrames == 0 && contourCPUReadbacks == 0 && contactCandidateOverflow == 0
                && bubblesMatchedInEveryFrame && measuredFramesComplete
        }
        /// Czy p95 pełnej klatki mieści się w bramce 60 FPS.
        public var passesGate: Bool { p95Milliseconds <= PublicWorldStressBenchmark.acceptanceGateMilliseconds }

        public var text: String {
            "level=\(bubbleCount); cooldown_s=\(String(format: "%.1f", cooldownSeconds)); "
                + "cooldown_timeout=\(cooldownTimedOut ? 1 : 0); thermal_worst=\(thermalWorst.capacityReportName); "
                + "valid=\(isValid ? 1 : 0); p95_ms=\(String(format: "%.4f", p95Milliseconds)); "
                + "host_non_gpu_p95_ms=\(String(format: "%.4f", hostNonGPUP95Milliseconds)); "
                + "gpu_physics_p95_ms=\(String(format: "%.4f", gpuPhysicsP95Milliseconds)); "
                + "gpu_render_estimate_ms=\(String(format: "%.4f", gpuRenderEstimateMilliseconds)); "
                + "max_candidates_per_object=\(maximumCandidatesPerObject); candidate_limit=\(candidateLimit); "
                + "failed_frames=\(failedFrames); non_finite_frames=\(nonFiniteFrames); "
                + "contour_cpu_readbacks=\(contourCPUReadbacks); contact_candidate_overflow=\(contactCandidateOverflow); "
                + "bubbles=\(bubblesMatchedInEveryFrame ? String(bubbleCount) : "mismatch")"
        }

        package init(bubbleCount: Int, cooldownSeconds: Double = 0, cooldownTimedOut: Bool = false,
                     thermalWorst: ProcessInfo.ThermalState = .nominal, p95Milliseconds: Double = 0,
                     hostNonGPUP95Milliseconds: Double = 0, gpuPhysicsP95Milliseconds: Double = 0,
                     gpuRenderEstimateMilliseconds: Double = 0, maximumCandidatesPerObject: Int = 0,
                     candidateLimit: Int = 128, failedFrames: Int = 0, nonFiniteFrames: Int = 0,
                     contourCPUReadbacks: Int = 0, contactCandidateOverflow: Int = 0,
                     bubblesMatchedInEveryFrame: Bool = true, measuredFramesComplete: Bool = true) {
            self.bubbleCount = bubbleCount; self.cooldownSeconds = cooldownSeconds; self.cooldownTimedOut = cooldownTimedOut
            self.thermalWorst = thermalWorst; self.p95Milliseconds = p95Milliseconds
            self.hostNonGPUP95Milliseconds = hostNonGPUP95Milliseconds
            self.gpuPhysicsP95Milliseconds = gpuPhysicsP95Milliseconds
            self.gpuRenderEstimateMilliseconds = gpuRenderEstimateMilliseconds
            self.maximumCandidatesPerObject = maximumCandidatesPerObject; self.candidateLimit = candidateLimit
            self.failedFrames = failedFrames; self.nonFiniteFrames = nonFiniteFrames
            self.contourCPUReadbacks = contourCPUReadbacks; self.contactCandidateOverflow = contactCandidateOverflow
            self.bubblesMatchedInEveryFrame = bubblesMatchedInEveryFrame
            self.measuredFramesComplete = measuredFramesComplete
        }

        /// Poziom z raportu przebiegu `run` (obie serie zsumowane) i czasu czekania przed nim.
        package init(_ report: PublicWorldStressReport, bubbleCount: Int, cooldownSeconds: Double, cooldownTimedOut: Bool) {
            self.init(bubbleCount: bubbleCount, cooldownSeconds: cooldownSeconds, cooldownTimedOut: cooldownTimedOut,
                      thermalWorst: report.worstThermalState, p95Milliseconds: report.p95Milliseconds,
                      hostNonGPUP95Milliseconds: report.hostNonGPUP95Milliseconds,
                      gpuPhysicsP95Milliseconds: report.gpuPhysicsP95Milliseconds,
                      gpuRenderEstimateMilliseconds: report.gpuRenderEstimateMilliseconds,
                      maximumCandidatesPerObject: report.maximumCandidatesPerObject, candidateLimit: report.candidateLimit,
                      failedFrames: report.failedFrames, nonFiniteFrames: report.nonFiniteFrames,
                      contourCPUReadbacks: report.contourCPUReadbacks,
                      contactCandidateOverflow: report.contactCandidateOverflow,
                      bubblesMatchedInEveryFrame: report.bubbleCountMismatchFrames == 0,
                      measuredFramesComplete: report.allSeriesComplete)
        }
    }

    /// Pojemność wg reguły G12-AC4.
    public enum Capacity: Equatable, Sendable {
        /// Największy poziom zdający razem ze wszystkimi niższymi.
        case bubbles(Int)
        /// Zdają wszystkie poziomy; wartość to największy z nich.
        case atLeastLargest(Int)
        /// Nie zdaje najmniejszy poziom; wartość to on.
        case belowSmallest(Int)
        /// Poziom z warunku reguły jest nieważny (termika albo naruszenie zer poprawności), pomiar trzeba powtórzyć.
        case undecidedThermal

        /// Wartość linii `capacity=`: liczba, `>=<największy>`, `<<najmniejszy>` albo `undecided_thermal`.
        public var reportText: String {
            switch self {
            case .bubbles(let count): return String(count)
            case .atLeastLargest(let count): return ">=\(count)"
            case .belowSmallest(let count): return "<\(count)"
            case .undecidedThermal: return "undecided_thermal"
            }
        }
    }

    public let deviceName: String
    public let warmupFrames: Int
    public let measuredFrames: Int
    public let levels: [Level]
    public let capacity: Capacity

    public var text: String {
        let header = """
        \(PublicWorldStressBenchmark.reportPathHeader)
        device=\(deviceName)
        scene=capacity
        warmup=\(warmupFrames); measured=\(measuredFrames)
        p95_gate_ms=\(String(format: "%.4f", PublicWorldStressBenchmark.acceptanceGateMilliseconds))
        """
        return ([header] + levels.map(\.text) + ["capacity=\(capacity.reportText)"]).joined(separator: "\n")
    }

    package init(deviceName: String, warmupFrames: Int, measuredFrames: Int, levels: [Level]) {
        self.deviceName = deviceName; self.warmupFrames = warmupFrames; self.measuredFrames = measuredFrames
        self.levels = levels; self.capacity = CapacityRule.evaluate(levels)
    }
}

/// Reguła pojemności: największy poziom, przy którym p95 pełnej klatki mieści się w bramce na nim i na wszystkich niższych.
/// Wszystkie te poziomy i pierwszy niezdający muszą być ważne (termika i zera poprawności), inaczej wynik jest nierozstrzygnięty. Gdy zdają
/// wszystkie, pojemność to „≥ największy” (pod warunkiem ważności wszystkich), a gdy nie zdaje najmniejszy, „< najmniejszy”.
/// Poziomy powyżej pierwszego niezdającego nie wpływają na wynik, także nieważne.
package enum CapacityRule {
    package static func evaluate(_ levels: [PublicWorldCapacityReport.Level]) -> PublicWorldCapacityReport.Capacity {
        let ordered = levels.sorted { $0.bubbleCount < $1.bubbleCount }
        guard let smallest = ordered.first, let largest = ordered.last else { return .undecidedThermal }
        guard let firstFailing = ordered.firstIndex(where: { !$0.passesGate }) else {
            return ordered.allSatisfy(\.isValid) ? .atLeastLargest(largest.bubbleCount) : .undecidedThermal
        }
        guard ordered[...firstFailing].allSatisfy(\.isValid) else { return .undecidedThermal }
        return firstFailing == 0 ? .belowSmallest(smallest.bubbleCount) : .bubbles(ordered[firstFailing - 1].bubbleCount)
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
