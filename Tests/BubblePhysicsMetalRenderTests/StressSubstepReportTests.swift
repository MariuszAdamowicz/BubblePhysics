import BubblePhysics
import BubblePhysicsMetalRender
import BubblePhysicsMetalRenderBenchmark
import Metal
import XCTest

/// P-B-28 (G8-AC1, G8-AC2): raport stress ma histogram podkroków, najdłuższą klatkę i czasy GPU fizyki i konturu z telemetrii klatek,
/// oraz czekanie CPU na bufor renderu jako część publikacji. Wartości raportu są porównywane z tym, co test sam zebrał z klatek
/// przez `frameObserver`, a nie z samym wystąpieniem klucza w tekście.
@MainActor
final class StressSubstepReportTests: XCTestCase {
    private func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * 0.95)) - 1)]
    }

    private struct Run {
        let report: PublicWorldStressReport
        /// Klatki mierzone serii z renderem (bez rozgrzewki), w kolejności.
        let measured: [PublicWorldStressFrameSample]
    }

    private func run(scene: PublicWorldStressBenchmark.Scene = .stress300, warmup: Int = 5, measured: Int = 40) async throws -> Run {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("brak urządzenia Metal") }
        var samples: [PublicWorldStressFrameSample] = []
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: scene,
            frameObserver: { samples.append($0) }, warmupFrames: warmup, measuredFrames: measured, progress: { _, _ in })
        XCTAssertEqual(report.failedFrames, 0)
        let frames = samples.filter { $0.series == .full && $0.index >= warmup }.sorted { $0.index < $1.index }
        XCTAssertEqual(frames.count, measured)
        return Run(report: report, measured: frames)
    }

    /// Wartość klucza z tekstu raportu: `key=value` kończy się średnikiem albo nową linią.
    private func value(of key: String, in text: String) throws -> String {
        let marker = key + "="
        let range = try XCTUnwrap(text.range(of: marker), "raport nie ma klucza \(key)")
        let rest = text[range.upperBound...]
        return String(rest.prefix { $0 != ";" && $0 != "\n" })
    }

    func testSubstepKeysComeFromTheTelemetryOfTheMeasuredFrames() async throws {
        let run = try await run()
        let counts = try run.measured.map { try XCTUnwrap($0.substepCount, "klatka \($0.index) bez telemetrii") }
        let report = run.report
        XCTAssertGreaterThanOrEqual(counts.min() ?? 0, 1)
        XCTAssertEqual(report.substepMax, counts.max())
        XCTAssertEqual(Double(report.substepP95), p95(counts.map(Double.init)))
        XCTAssertEqual(report.substepHistogram, Dictionary(counts.map { ($0, 1) }, uniquingKeysWith: +))
        XCTAssertEqual(report.substepHistogram.values.reduce(0, +), run.measured.count, "histogram obejmuje każdą klatkę mierzoną")
        XCTAssertEqual(report.gridRebuildMax, run.measured.compactMap(\.gridRebuildCount).max())
    }

    /// P-B-40: stress-300 (287 baniek) liczy się jedną dyspozycją, więc raport podaje 1 bufor podkroków w każdej klatce, ścieżkę
    /// `singleDispatch` i szerokość grupy z potoku; klucze tekstu mają wartości raportu.
    func testExecutionPathKeysDescribeTheSingleDispatchPath() async throws {
        let report = try await run().report
        XCTAssertEqual(report.substepBuffersMax, 1, "jedna dyspozycja ma jeden bufor podkroków w każdej klatce")
        XCTAssertEqual(report.executionPath, "singleDispatch")
        XCTAssertTrue((1...1024).contains(report.singleGroupWidth), "szerokość grupy \(report.singleGroupWidth)")
        let text = report.text
        XCTAssertEqual(try value(of: "substep_buffers_max", in: text), String(report.substepBuffersMax))
        XCTAssertEqual(try value(of: "execution_path", in: text), report.executionPath)
        XCTAssertEqual(try value(of: "single_group_width", in: text), String(report.singleGroupWidth))
    }

    /// P-B-40: klucze ścieżki raportu to agregaty z pól klatek (`PublicWorldStressFrameSample`): maksimum buforów podkroków i szerokości
    /// grupy oraz wspólna ścieżka klatek. Test liczy je z klatek sam, więc nie zależy od tego, którą ścieżkę wybrał silnik.
    func testExecutionPathKeysAreAggregatedFromTheFrameSamples() async throws {
        let run = try await run(measured: 20)
        let buffers = try run.measured.map { try XCTUnwrap($0.substepBufferCount, "klatka \($0.index) bez liczby buforów podkroków") }
        let paths = Set(try run.measured.map { try XCTUnwrap($0.executionPath, "klatka \($0.index) bez ścieżki") })
        let widths = try run.measured.map { try XCTUnwrap($0.singleGroupWidth, "klatka \($0.index) bez szerokości grupy") }
        XCTAssertGreaterThanOrEqual(buffers.min() ?? 0, 1, "każda klatka ma co najmniej jeden bufor podkroków")
        XCTAssertEqual(run.report.substepBuffersMax, buffers.max())
        XCTAssertEqual(paths.count, 1, "scena stress-300 liczy się jedną ścieżką w każdej klatce: \(paths)")
        XCTAssertEqual(run.report.executionPath, paths.first)
        XCTAssertEqual(run.report.singleGroupWidth, widths.max())
        XCTAssertEqual(try value(of: "execution_path", in: run.report.text), paths.first)
    }

    /// P-B-40: `grid_rebuild_max` liczy przebudowy wymuszone zapasem, a nie pary buforów; jedna dyspozycja nie może mieć ich więcej
    /// niż podkroków w klatce.
    func testGridRebuildMaxCountsMarginRebuildsOnly() async throws {
        let run = try await run(scene: .restingCrowd)
        XCTAssertEqual(run.report.gridRebuildMax, 0, "tłum w spoczynku nie wyczerpuje zapasu obwiedni")
        XCTAssertEqual(run.report.executionPath, "singleDispatch")
    }

    func testLongestFrameAndGPUTimesComeFromTheMeasuredFrames() async throws {
        let run = try await run()
        let report = run.report
        XCTAssertEqual(report.longestFrameMilliseconds, run.measured.map(\.elapsedMilliseconds).max() ?? 0, accuracy: 1e-9)
        XCTAssertEqual(report.longestFrameMilliseconds, report.maximumMilliseconds, accuracy: 1e-9)
        XCTAssertEqual(report.telemetryPhysicsGPUP95Milliseconds,
                       p95(run.measured.compactMap(\.physicsGPUMilliseconds)), accuracy: 1e-9)
        XCTAssertEqual(report.telemetryContourGPUP95Milliseconds,
                       p95(run.measured.compactMap(\.contourGPUMilliseconds)), accuracy: 1e-9)
        XCTAssertGreaterThan(report.telemetryPhysicsGPUP95Milliseconds, 0, "fizyka ma czas GPU")
        XCTAssertGreaterThan(report.telemetryContourGPUP95Milliseconds, 0, "kontur ma czas GPU")
    }

    func testRenderWaitIsPartOfTheHostPublicationNotASeparateSegment() async throws {
        let run = try await run()
        let report = run.report
        for sample in run.measured {
            XCTAssertGreaterThan(sample.renderWaitMilliseconds, 0, "klatka \(sample.index) czeka na bufor renderu")
            XCTAssertLessThanOrEqual(sample.renderWaitMilliseconds, sample.publicationMilliseconds + 0.05,
                                     "czekanie na render mieści się w publikacji klatki \(sample.index)")
        }
        XCTAssertEqual(report.hostRenderWaitP95Milliseconds, p95(run.measured.map(\.renderWaitMilliseconds)), accuracy: 1e-9)
        XCTAssertGreaterThan(report.hostRenderWaitP95Milliseconds, 0)
        XCTAssertLessThanOrEqual(report.hostRenderWaitP95Milliseconds, report.hostPublicationP95Milliseconds + 0.05)
        // Suma odcinków klatki zostaje bez zmian: render nie dochodzi jako czwarty odcinek.
        for sample in run.measured {
            let sum = sample.preparationMilliseconds + sample.encodingMilliseconds + sample.waitingMilliseconds
                + sample.publicationMilliseconds
            XCTAssertEqual(sum, sample.elapsedMilliseconds, accuracy: 0.2, "odcinki klatki \(sample.index) dają czas klatki")
        }
    }

    func testReportTextCarriesTheNewKeysWithTheReportValues() async throws {
        let report = try await run().report
        let text = report.text
        XCTAssertEqual(try value(of: "substep_p95", in: text), String(report.substepP95))
        XCTAssertEqual(try value(of: "substep_max", in: text), String(report.substepMax))
        XCTAssertEqual(try value(of: "grid_rebuild_max", in: text), String(report.gridRebuildMax))
        XCTAssertEqual(try value(of: "substep_histogram", in: text), PublicWorldStressReport.substepHistogramText(report.substepHistogram))
        XCTAssertFalse(try value(of: "substep_histogram", in: text).isEmpty)
        XCTAssertEqual(try XCTUnwrap(Double(value(of: "longest_frame_ms", in: text))), report.longestFrameMilliseconds, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(Double(value(of: "host_render_wait_p95_ms", in: text))),
                       report.hostRenderWaitP95Milliseconds, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(Double(value(of: "telemetry_physics_gpu_p95_ms", in: text))),
                       report.telemetryPhysicsGPUP95Milliseconds, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(Double(value(of: "telemetry_contour_gpu_p95_ms", in: text))),
                       report.telemetryContourGPUP95Milliseconds, accuracy: 1e-4)
        // Dotychczasowe klucze zostają: prognoza iPhone'a X czyta `gpu_physics_p95_ms` z serii samej fizyki.
        XCTAssertGreaterThan(try XCTUnwrap(Double(value(of: "gpu_physics_p95_ms", in: text))), 0)
        XCTAssertTrue(text.contains("host_publication_p95_ms="))
        XCTAssertTrue(text.contains("host_waiting_p95_ms="))
    }

    func testHistogramTextUsesPowerOfTwoBucketsInAscendingOrderAndSkipsEmptyOnes() {
        XCTAssertEqual(PublicWorldStressReport.substepHistogramText([:]), "")
        XCTAssertEqual(PublicWorldStressReport.substepHistogramText([1: 290, 2: 6, 3: 1, 4: 2, 9: 1, 1024: 1]),
                       "1:290,2:6,3-4:3,9-16:1,513-1024:1")
        XCTAssertEqual(PublicWorldStressReport.substepHistogramText([5: 2, 8: 1, 6: 1]), "5-8:4")
    }

    /// Krok bez ciał nie uruchamia solvera, więc czekanie na render z profilu poprzedniego kroku nie może zostać w pomiarze.
    func testRenderWaitOfTheSolverIsNotKeptByAStepWithoutBodies() async throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw XCTSkip("brak urządzenia Metal") }
        let scene = PublicWorldStressBenchmark.Scene.restingCrowd
        let world = try BubbleWorld.makeBenchmarkWorld(configuration: scene.configuration(), device: device)
        let transaction = try scene.initialTransaction(assets: XCTUnwrap(world.assets))
        world.submit(transaction)
        func advance() async throws {
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            _ = await world.advance(by: 1.0 / 60, commandBuffer: command) {}
            XCTAssertEqual(command.status, .completed)
        }
        try await advance()
        XCTAssertGreaterThan(try XCTUnwrap(world.benchmarkFrameProfile).renderWaitMilliseconds, 0, "krok z solverem czeka na bufor renderu")
        var removal = WorldTransaction()
        for case .add(let object) in transaction.operations {
            switch object {
            case .bubble(let bubble): removal = removal.remove(bubble.id)
            case .rigidBody(let body): removal = removal.remove(body.id)
            default: break
            }
        }
        world.submit(removal)
        try await advance()
        XCTAssertEqual(world.benchmarkFrameProfile?.renderWaitMilliseconds ?? 0, 0, "krok bez ciał nie uruchomił solvera")
        try await advance()
        XCTAssertEqual(world.benchmarkFrameProfile?.renderWaitMilliseconds ?? 0, 0, "kolejny krok bez ciał")
    }
}
