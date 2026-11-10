import BubblePhysics
import BubblePhysicsAssets
import BubblePhysicsMetalRender
import CoreGraphics
import Metal
import XCTest

/// P-B-61 na Macu: skład sceny akceptacyjnej, rozmiar celu renderu, pola raportu i bramka sceny.
/// Pomiar na iPhonie X należy do właściciela; te testy pilnują, że to, co mierzy, jest tą sceną.
@MainActor
final class AcceptanceSceneTests: XCTestCase {
    private typealias Scene = PublicWorldStressBenchmark.Scene

    private func acceptanceOperations() throws -> [WorldOperation] {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let scene = Scene.acceptance
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: scene.configuration(), device: device, solverIterationLimit: 4)
        return try scene.initialTransaction(assets: XCTUnwrap(world.assets)).operations
    }

    func testSceneHasThreeHundredTexturedBubblesWithTextDecalsOnTwoLayersOfAlphaMaterials() throws {
        let operations = try acceptanceOperations()
        var materials: [RenderMaterialID: RenderMaterial] = [:]
        var bubbles: [BubbleDescriptor] = []
        for operation in operations {
            switch operation {
            case .updateRenderMaterial(let id, let material): materials[id] = material
            case .add(.bubble(let bubble)): bubbles.append(bubble)
            default: break
            }
        }
        XCTAssertEqual(bubbles.count, 300)
        for bubble in bubbles {
            guard case .text? = bubble.decal?.content else { XCTFail("bańka \(bubble.id) bez naklejki tekstowej"); continue }
            let material = try XCTUnwrap(materials[bubble.renderMaterialID], "materiał bańki \(bubble.id)")
            XCTAssertNotNil(material.texture, "bańka \(bubble.id) ma teksturę")
            XCTAssertEqual(material.bubbleMapping, .attached)
            XCTAssertEqual(material.blend, .alpha, "bańka \(bubble.id) na warstwie \(bubble.layer) ma materiał alfa")
        }
        XCTAssertEqual(Set(bubbles.map(\.layer)), [0, 1])
        XCTAssertEqual(bubbles.filter { $0.layer == 1 }.count, 150)
        XCTAssertEqual(bubbles.filter { $0.layer == 0 }.count, 150)
    }

    func testSceneHasFourWallsAndAKinematicTriangleWithADrive() throws {
        let operations = try acceptanceOperations()
        var statics: [RigidBodyDescriptor] = []
        var kinematic: [RigidBodyDescriptor] = []
        var drives: [ObjectID: KinematicDrive] = [:]
        for operation in operations {
            switch operation {
            case .add(.rigidBody(let body)):
                if body.motionRole == .kinematic { kinematic.append(body) } else { statics.append(body) }
            case .setKinematicDrive(let id, let drive): drives[id] = drive
            default: break
            }
        }
        XCTAssertEqual(statics.count, 4)
        XCTAssertTrue(statics.allSatisfy { $0.motionRole == .static })
        XCTAssertEqual(kinematic.count, 1)
        let triangle = try XCTUnwrap(kinematic.first)
        guard case .polygon(let geometry) = triangle.shape else { return XCTFail("trójkąt jest wielokątem") }
        XCTAssertEqual(geometry.vertices.count, 3)
        XCTAssertNotNil(drives[triangle.id], "trójkąt kinematyczny ma KinematicDrive")
    }

    /// Rozmiar celu renderu czytany z tekstury, którą benchmark faktycznie utworzył, a nie z pól raportu.
    private func renderTargetSize(device: MTLDevice, size: CGSize?) async throws -> (width: Int, height: Int) {
        var observed: [(Int, Int)] = []
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance, renderSize: size,
            renderTargetObserver: { observed.append(($0.width, $0.height)) },
            warmupFrames: 0, measuredFrames: 2, progress: { _, _ in })
        XCTAssertEqual(report.failedFrames, 0)
        XCTAssertEqual(observed.count, 1, "jeden cel renderu na przebieg")
        let texture = try XCTUnwrap(observed.first)
        XCTAssertEqual(report.renderWidth, texture.0, "raport zgadza się z celem")
        XCTAssertEqual(report.renderHeight, texture.1, "raport zgadza się z celem")
        XCTAssertTrue(report.text.contains("render_px=\(texture.0)x\(texture.1)"))
        return texture
    }

    func testRenderTargetSizeFollowsTheRequestAndDefaultsToTheRegionAtWidth375() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let native = try await renderTargetSize(device: device, size: CGSize(width: 1125, height: 2436))
        XCTAssertEqual(native.width, 1125)
        XCTAssertEqual(native.height, 2436)
        let standard = try await renderTargetSize(device: device, size: nil)
        XCTAssertEqual(standard.width, 375)
        XCTAssertEqual(standard.height, 700, "region sceny akceptacyjnej ma 700 jednostek wysokości")
    }

    /// Bez ekranu startowego iPhone X uruchamia aplikację w trybie zgodności 320 × 480 pt, a `UIScreen.main.nativeBounds`
    /// zwraca wtedy 960 × 1440 zamiast 1125 × 2436 (pomiar 2026-11-10). Aplikacja benchmarku musi więc generować ekran startowy.
    func testBenchmarkAppGeneratesALaunchScreenSoThatNativeBoundsIsTheFullDeviceScreen() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let project = root.appendingPathComponent("Benchmarks/iOS/BubblePhysicsBench")
        let spec = try String(contentsOf: project.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertTrue(spec.contains("INFOPLIST_KEY_UILaunchScreen_Generation: YES"), "project.yml")
        let pbxproj = try String(contentsOf: project.appendingPathComponent(
            "BubblePhysicsBench.xcodeproj/project.pbxproj"), encoding: .utf8)
        let configurations = pbxproj.components(separatedBy: "GENERATE_INFOPLIST_FILE = YES;").count - 1
        let launchScreens = pbxproj.components(separatedBy: "INFOPLIST_KEY_UILaunchScreen_Generation = YES;").count - 1
        XCTAssertEqual(configurations, 2, "Debug i Release")
        XCTAssertEqual(launchScreens, configurations, "każda konfiguracja generuje ekran startowy")
    }

    func testInvalidRenderSizeThrowsADedicatedErrorInsteadOfTrapping() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let invalid: [CGSize] = [
            CGSize(width: 0, height: 100), CGSize(width: 100, height: 0), CGSize(width: -375, height: 700),
            CGSize(width: CGFloat.nan, height: 700), CGSize(width: 375, height: CGFloat.nan),
            CGSize(width: CGFloat.infinity, height: 700), CGSize(width: 375, height: -CGFloat.infinity),
            CGSize(width: 1e30, height: 700), CGSize(width: 0.5, height: 700)
        ]
        for size in invalid {
            do {
                _ = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance, renderSize: size,
                    warmupFrames: 0, measuredFrames: 1, progress: { _, _ in })
                XCTFail("rozmiar \(size) powinien zostać odrzucony")
            } catch let error as StressBenchmarkError {
                guard case .invalidRenderSize = error else { XCTFail("rozmiar \(size): \(error)"); continue }
            }
        }
    }

    func testFiveFramesKeepCandidateMarginAndReadNoContours() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance,
            warmupFrames: 0, measuredFrames: 5, progress: { _, _ in })
        XCTAssertEqual(report.scene, "acceptance")
        XCTAssertEqual(report.measuredFrames, 5)
        XCTAssertEqual(report.failedFrames, 0)
        XCTAssertEqual(report.nonFiniteFrames, 0)
        XCTAssertEqual(report.contourCPUReadbacks, 0)
        XCTAssertEqual(report.contactCandidateOverflow, 0)
        XCTAssertEqual(report.candidateLimit, BubbleWorld.contactCandidateLimit)
        XCTAssertGreaterThan(report.maximumCandidatesPerObject, 0, "scena ma kontakty, więc licznik coś zmierzył")
        XCTAssertLessThanOrEqual(report.maximumCandidatesPerObject * 2, report.candidateLimit)
        XCTAssertTrue(report.text.contains("scene=acceptance"))
        XCTAssertTrue(report.text.contains("contact_candidate_overflow=0; max_candidates_per_object=\(report.maximumCandidatesPerObject); candidate_limit=128"))
    }

    func testAcceptanceGateIs16Point67AndOtherScenesKeepTheirGate() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let acceptance = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance,
            warmupFrames: 0, measuredFrames: 2, progress: { _, _ in })
        XCTAssertEqual(acceptance.gateMilliseconds, 16.67, accuracy: 1e-9)
        XCTAssertTrue(acceptance.text.contains("p95_gate_ms=16.6700"))
        XCTAssertEqual(acceptance.passesP95Gate, acceptance.p95Milliseconds <= 16.67)
        let stress = try await PublicWorldStressBenchmark.run(device: device, scene: .stress300,
            warmupFrames: 0, measuredFrames: 2, progress: { _, _ in })
        XCTAssertEqual(stress.gateMilliseconds, PublicWorldStressBenchmark.p95GateMilliseconds, accuracy: 1e-9)
        XCTAssertTrue(stress.text.contains("p95_gate_ms=10.4568"))
    }

    // MARK: - Składowe raportu (P-B-78)

    private func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private struct ObservedRun {
        let report: PublicWorldStressReport
        let samples: [PublicWorldStressFrameSample]
        let renderTargets: Int
        let warmup: Int
        let measured: Int
        func series(_ kind: PublicWorldStressFrameSample.Series) -> [PublicWorldStressFrameSample] {
            samples.filter { $0.series == kind }.sorted { $0.index < $1.index }
        }
    }

    private func observedRun(warmup: Int = 4, measured: Int = 12) async throws -> ObservedRun {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        var samples: [PublicWorldStressFrameSample] = []
        var targets = 0
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: .acceptance,
            renderTargetObserver: { _ in targets += 1 }, frameObserver: { samples.append($0) },
            warmupFrames: warmup, measuredFrames: measured, progress: { _, _ in })
        XCTAssertEqual(report.failedFrames, 0)
        return ObservedRun(report: report, samples: samples, renderTargets: targets, warmup: warmup, measured: measured)
    }

    func testReportHasPreparationPublicationAndPhysicsLinesAndFields() async throws {
        let run = try await observedRun()
        let report = run.report
        for value in [report.hostPreparationP95Milliseconds, report.hostPublicationP95Milliseconds,
                      report.gpuPhysicsP95Milliseconds] {
            XCTAssertTrue(value.isFinite && value > 0, "składowa raportu \(value)")
        }
        XCTAssertEqual(report.gpuRenderEstimateMilliseconds, report.gpuP95Milliseconds - report.gpuPhysicsP95Milliseconds,
                       accuracy: 1e-12)
        let lines = report.text.split(separator: "\n").map(String.init)
        func fixed(_ value: Double) -> String { String(format: "%.4f", value) }
        XCTAssertTrue(lines.contains("host_preparation_p95_ms=\(fixed(report.hostPreparationP95Milliseconds)); host_publication_p95_ms=\(fixed(report.hostPublicationP95Milliseconds))"),
                      report.text)
        XCTAssertTrue(lines.contains("gpu_physics_p95_ms=\(fixed(report.gpuPhysicsP95Milliseconds)); gpu_render_estimate_ms=\(fixed(report.gpuRenderEstimateMilliseconds))"),
                      report.text)
        // Dotychczasowe linie zostają, bo parser raportu iPhone'a i raporty z urządzenia z 2026-11-10 na nich stoją.
        XCTAssertTrue(lines.contains { $0.hasPrefix("host_encoding_p95_ms=") && $0.contains("; host_waiting_p95_ms=") })
        XCTAssertTrue(lines.contains { $0.hasPrefix("gpu_p95_ms=") && $0.contains("; host_non_gpu_p95_ms=") })
    }

    func testReportComponentsAreTheP95OfTheMeasuredFramesOfTheirSeries() async throws {
        let run = try await observedRun()
        let full = run.series(.full).filter { $0.index >= run.warmup }
        let physics = run.series(.physicsOnly).filter { $0.index >= run.warmup }
        XCTAssertEqual(full.count, run.measured)
        XCTAssertEqual(physics.count, run.measured)
        XCTAssertEqual(run.report.hostPreparationP95Milliseconds, p95(full.map(\.preparationMilliseconds)), accuracy: 1e-9)
        XCTAssertEqual(run.report.hostPublicationP95Milliseconds, p95(full.map(\.publicationMilliseconds)), accuracy: 1e-9)
        XCTAssertEqual(run.report.hostEncodingP95Milliseconds, p95(full.map(\.encodingMilliseconds)), accuracy: 1e-9)
        XCTAssertEqual(run.report.hostWaitingP95Milliseconds, p95(full.map(\.waitingMilliseconds)), accuracy: 1e-9)
        XCTAssertEqual(run.report.gpuPhysicsP95Milliseconds, p95(physics.map(\.gpuMilliseconds)), accuracy: 1e-9,
                       "gpu_physics_p95_ms pochodzi z drugiej serii, nie z serii z renderem")
        XCTAssertEqual(run.report.gpuP95Milliseconds, p95(full.map(\.gpuMilliseconds)), accuracy: 1e-9)
    }

    func testSecondSeriesRunsTheSameStepsOnAFreshWorldWithoutRenderingAndWithIdenticalPhysics() async throws {
        let run = try await observedRun()
        let total = run.warmup + run.measured
        let full = run.series(.full), physics = run.series(.physicsOnly)
        XCTAssertEqual(full.map(\.index), Array(0..<total), "ta sama rozgrzewka i te same indeksy kroków")
        XCTAssertEqual(physics.map(\.index), Array(0..<total), "ta sama rozgrzewka i te same indeksy kroków")
        XCTAssertTrue(full.allSatisfy(\.renderEncoded), "seria z renderem koduje render w każdej klatce")
        XCTAssertTrue(physics.allSatisfy { !$0.renderEncoded }, "druga seria ma pusty encodeRender")
        XCTAssertEqual(run.renderTargets, 1, "druga seria nie tworzy własnego celu renderu")
        for (a, b) in zip(full, physics) {
            XCTAssertEqual(a.frame.stepIndex, UInt64(a.index + 1))
            XCTAssertEqual(b.frame.stepIndex, a.frame.stepIndex, "świeży świat dochodzi do tego samego kroku")
            XCTAssertEqual(a.frame.objects, b.frame.objects, "fizyka obu serii jest identyczna w klatce \(a.index)")
        }
    }

    func testStageComponentsAddUpToTheFrameTimeInEveryFrame() async throws {
        let run = try await observedRun()
        let full = run.series(.full)
        XCTAssertEqual(full.count, run.warmup + run.measured)
        for sample in full {
            let parts = [sample.preparationMilliseconds, sample.encodingMilliseconds, sample.waitingMilliseconds,
                         sample.publicationMilliseconds]
            XCTAssertTrue(parts.allSatisfy { $0.isFinite && $0 > 0 }, "klatka \(sample.index): \(parts)")
            let sum = parts.reduce(0, +)
            XCTAssertLessThanOrEqual(sum, sample.elapsedMilliseconds + 1e-6, "klatka \(sample.index)")
            XCTAssertGreaterThanOrEqual(sum, sample.elapsedMilliseconds * 0.99,
                "składowe pokrywają czas klatki, bez dziur, klatka \(sample.index)")
        }
    }

    /// Przygotowanie to start `advance` → początek kodowania, a publikacja to koniec oczekiwania → powrót z `advance`;
    /// zamiana tych dwóch składowych miejscami zachowałaby sumę, więc pilnuje tego porównanie ze znacznikami profilu.
    func testPreparationAndPublicationAreTheirOwnIntervalsOfTheFrameProfile() async throws {
        let run = try await observedRun()
        for sample in run.series(.full) {
            XCTAssertLessThan(sample.startNanoseconds, sample.encodingStartNanoseconds, "klatka \(sample.index)")
            XCTAssertLessThan(sample.encodingStartNanoseconds, sample.waitingEndNanoseconds, "klatka \(sample.index)")
            XCTAssertLessThanOrEqual(sample.waitingEndNanoseconds, sample.endNanoseconds, "klatka \(sample.index)")
            XCTAssertEqual(sample.preparationMilliseconds,
                Double(sample.encodingStartNanoseconds - sample.startNanoseconds) / 1_000_000, accuracy: 1e-9,
                "przygotowanie: początek advance → początek kodowania, klatka \(sample.index)")
            XCTAssertEqual(sample.publicationMilliseconds,
                Double(sample.endNanoseconds - sample.waitingEndNanoseconds) / 1_000_000, accuracy: 1e-9,
                "publikacja: koniec oczekiwania → powrót z advance, klatka \(sample.index)")
        }
    }
}
