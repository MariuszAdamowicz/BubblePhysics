import BubblePhysicsMetalRender
import CoreGraphics
import Foundation
import Metal

/// Punkt odniesienia jednej sceny: p95 pełnej klatki (krok fizyki i render) jako mediana z kilku przebiegów.
struct PerfGuardScenePoint: Codable, Equatable {
    var p95Milliseconds: Double
    var runs: [Double]
    var recordedAt: String
    var note: String
}

/// Zawartość `docs/benchmarks/perf-guard.json`. Punkty odniesienia mają sens tylko na tym samym urządzeniu.
struct PerfGuardBaseline: Codable, Equatable {
    var device: String
    var scenes: [String: PerfGuardScenePoint]

    static func load(from url: URL) throws -> PerfGuardBaseline {
        try JSONDecoder().decode(PerfGuardBaseline.self, from: Data(contentsOf: url))
    }

    static func loadIfPresent(from url: URL) throws -> PerfGuardBaseline? {
        FileManager.default.fileExists(atPath: url.path) ? try load(from: url) : nil
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    }

    func recording(scene: String, runs: [Double], recordedAt: String, note: String) -> PerfGuardBaseline {
        var copy = self
        copy.scenes[scene] = PerfGuardScenePoint(p95Milliseconds: PerfGuard.median(runs), runs: runs,
            recordedAt: recordedAt, note: note)
        return copy
    }
}

struct PerfGuardSceneResult: Equatable {
    let scene: String
    let runs: [Double]
    let medianP95Milliseconds: Double
    let baselineMilliseconds: Double?
    let passed: Bool
    let detail: String
}

/// Skalowanie CPU przygotowania i publikacji kroku: czas dla 600 obiektów podzielony przez czas dla 300 (G12-AC1).
struct PerfGuardScalingResult: Equatable {
    let small: Double
    let large: Double
    let ratio: Double
    let passed: Bool
    var text: String {
        let verdict = passed ? "PASS" : "FAIL"
        guard ratio.isFinite else {
            return "scaling 600/300: \(verdict) pomiar nie jest skończony ani dodatni (300: \(small) ms, 600: \(large) ms)"
        }
        return "scaling 600/300: \(String(format: "%.2f", ratio)) (limit \(String(format: "%.2f", PerfGuard.scalingLimit))) \(verdict); CPU poza GPU p95 300: \(String(format: "%.4f", small)) ms, 600: \(String(format: "%.4f", large)) ms"
    }
}

struct PerfGuardReport {
    let results: [PerfGuardSceneResult]
    var scaling: PerfGuardScalingResult?
    var passed: Bool { results.allSatisfy(\.passed) && scaling?.passed != false }
    var text: String {
        var lines = results.map { "\($0.passed ? "PASS" : "FAIL") \($0.scene): \($0.detail)" }
        if let scaling { lines.append(scaling.text) }
        return lines.joined(separator: "\n")
    }
}

struct PerfGuardOptions: Equatable {
    var recordScene: String?
    /// `--scene`: mierzy tylko tę scenę (bez skalowania 600/300).
    var scene: String?
    /// `--calibrate`: ścieżka raportu iPhone'a; zapisuje plik kalibracji z pomiaru sceny `acceptance` na Macu.
    var calibrateReportPath: String?
    /// `--check-prediction`: ścieżka raportu iPhone'a; porównuje z nim prognozę, kod 1 przy błędzie > 10%.
    var checkPredictionReportPath: String?
    var runs = 5
    var warmupFrames = 30
    var measuredFrames = 300
    var baselinePath = "docs/benchmarks/perf-guard.json"
    var injectedSlowdown = 0.0
    var note = "punkt odniesienia zapisany ręcznie przez --record"

    enum ParseError: Error, CustomStringConvertible, Equatable {
        case invalidArgument(String)
        var description: String {
            switch self { case .invalidArgument(let value): return "Nieprawidłowy argument: \(value)" }
        }
    }

    static let usage = "Użycie: BubblePhysicsPerfGuard [--record <scena>] [--scene <scena>] [--calibrate <raport>] [--check-prediction <raport>] [--runs N] [--warmup N] [--measured N] [--baseline ścieżka] [--inject-slowdown ułamek] [--note tekst]\nSceny: \(PerfGuard.scenes.joined(separator: ", "))"

    static func parse(_ arguments: [String]) throws -> PerfGuardOptions {
        var result = PerfGuardOptions()
        var index = 0
        while index < arguments.count {
            let option = arguments[index]
            guard index + 1 < arguments.count else { throw ParseError.invalidArgument(option) }
            let value = arguments[index + 1]
            switch option {
            case "--record":
                guard PerfGuard.scenes.contains(value) else { throw ParseError.invalidArgument(value) }
                result.recordScene = value
            case "--runs", "--warmup", "--measured":
                guard let count = Int(value), count >= (option == "--warmup" ? 0 : 1) else {
                    throw ParseError.invalidArgument(value)
                }
                switch option {
                case "--runs": result.runs = count
                case "--warmup": result.warmupFrames = count
                default: result.measuredFrames = count
                }
            case "--scene":
                guard PerfGuard.scenes.contains(value) else { throw ParseError.invalidArgument(value) }
                result.scene = value
            case "--calibrate":
                guard result.checkPredictionReportPath == nil else { throw ParseError.invalidArgument(option) }
                result.calibrateReportPath = value
            case "--check-prediction":
                guard result.calibrateReportPath == nil else { throw ParseError.invalidArgument(option) }
                result.checkPredictionReportPath = value
            case "--baseline": result.baselinePath = value
            case "--inject-slowdown":
                guard let fraction = Double(value), fraction.isFinite, fraction >= 0 else {
                    throw ParseError.invalidArgument(value)
                }
                result.injectedSlowdown = fraction
            case "--note": result.note = value
            default: throw ParseError.invalidArgument(option)
            }
            index += 2
        }
        if result.calibrateReportPath != nil || result.checkPredictionReportPath != nil,
           let scene = result.scene, scene != PerfGuard.predictionScene {
            throw ParseError.invalidArgument(scene)
        }
        return result
    }
}

enum PerfGuard {
    /// Sceny, które strażnik umie zmierzyć.
    static let scenes = ["stress-300", "mixed", "decals", "acceptance"]
    /// Scena prognozy iPhone'a X i kalibracji.
    static let predictionScene = "acceptance"
    /// Plik kalibracji z jednego commitu raportu iPhone'a i pomiaru na Macu.
    static let calibrationPath = "docs/benchmarks/iphone-x-calibration.json"
    /// Natywna rozdzielczość iPhone'a X w pikselach, w jakiej strażnik mierzy scenę `acceptance`.
    static let acceptanceRenderSize = CGSize(width: 1125, height: 2436)
    /// Dopuszczalne pogorszenie względem punktu odniesienia (G12-AC3).
    static let regressionTolerance = 0.10
    /// Liczby obiektów porównywane przy skalowaniu CPU.
    static let scalingSizes = (small: 300, large: 600)
    /// Największy dopuszczalny stosunek czasu CPU dla 600 do czasu dla 300 obiektów (G12-AC1).
    static let scalingLimit = 2.5

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return .infinity }
        let middle = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
    }

    /// Mierzy każdą scenę `runs` razy; wynik sceny to mediana p95 z przebiegów.
    /// `injectedSlowdown` (ułamek, np. 0,2) mnoży zmierzone czasy i służy do sprawdzenia, że strażnik reaguje.
    @MainActor
    static func check(scenes: [String], baseline: PerfGuardBaseline?, device: String, runs: Int,
                      injectedSlowdown: Double = 0,
                      measure: @MainActor (String) async throws -> Double,
                      scalingMeasure: (@MainActor (Int) async throws -> Double)? = nil) async throws -> PerfGuardReport {
        var results: [PerfGuardSceneResult] = []
        for scene in scenes {
            var samples: [Double] = []
            for _ in 0..<runs { samples.append(try await measure(scene) * (1 + injectedSlowdown)) }
            results.append(evaluate(scene: scene, runs: samples, baseline: baseline, device: device))
        }
        let scaling = try await scalingMeasure.asyncMap { try await checkScaling(runs: runs, measure: $0) }
        return PerfGuardReport(results: results, scaling: scaling)
    }

    /// Mierzy czas CPU kroku dla 300 i dla 600 obiektów `runs` razy; wynik to stosunek median.
    @MainActor
    static func checkScaling(runs: Int,
                             measure: @MainActor (Int) async throws -> Double) async throws -> PerfGuardScalingResult {
        var small: [Double] = [], large: [Double] = []
        for _ in 0..<runs {
            small.append(try await measure(scalingSizes.small))
            large.append(try await measure(scalingSizes.large))
        }
        return evaluateScaling(small: median(small), large: median(large))
    }

    static func evaluateScaling(small: Double, large: Double) -> PerfGuardScalingResult {
        guard small.isFinite, large.isFinite, small > 0, large > 0 else {
            return PerfGuardScalingResult(small: small, large: large, ratio: .nan, passed: false)
        }
        let ratio = large / small
        return PerfGuardScalingResult(small: small, large: large, ratio: ratio, passed: ratio <= scalingLimit + 1e-9)
    }

    static func evaluate(scene: String, runs: [Double], baseline: PerfGuardBaseline?,
                         device: String) -> PerfGuardSceneResult {
        let measured = median(runs)
        func result(_ passed: Bool, _ reference: Double?, _ detail: String) -> PerfGuardSceneResult {
            PerfGuardSceneResult(scene: scene, runs: runs, medianP95Milliseconds: measured,
                baselineMilliseconds: reference, passed: passed, detail: detail)
        }
        let measuredText = String(format: "%.4f", measured)
        guard measured.isFinite else { return result(false, nil, "pomiar nie jest skończony") }
        guard let baseline else {
            return result(false, nil, "brak punktu odniesienia (p95 \(measuredText) ms); zapisz go przez --record \(scene)")
        }
        guard baseline.device == device else {
            return result(false, nil, "punkt odniesienia pochodzi z innego urządzenia (\(baseline.device)), a pomiar z \(device); zapisz nowy przez --record \(scene)")
        }
        guard let point = baseline.scenes[scene] else {
            return result(false, nil, "brak punktu odniesienia (p95 \(measuredText) ms); zapisz go przez --record \(scene)")
        }
        let limit = point.p95Milliseconds * (1 + regressionTolerance)
        let ratio = measured / point.p95Milliseconds
        let detail = "p95 \(measuredText) ms, punkt odniesienia \(String(format: "%.4f", point.p95Milliseconds)) ms, limit \(String(format: "%.4f", limit)) ms (\(String(format: "%+.1f", (ratio - 1) * 100))%)"
        return result(measured <= limit + 1e-9, point.p95Milliseconds, detail)
    }

    /// Skrót dla `stress-300`.
    @MainActor
    static func measureStress300(device: MTLDevice, warmupFrames: Int, measuredFrames: Int) async throws -> Double {
        try await measureScene(.stress300, device: device, warmupFrames: warmupFrames, measuredFrames: measuredFrames)
    }

    /// Rozmiar celu renderu w pikselach dla sceny; `nil` to 375 × wysokość regionu sceny.
    static func renderSize(for scene: PublicWorldStressBenchmark.Scene) -> CGSize? {
        scene == .acceptance ? acceptanceRenderSize : nil
    }

    /// Jeden przebieg sceny przez `BubbleWorld` i bezpośredni renderer; zwraca pełny raport przebiegu.
    @MainActor
    static func measureSceneReport(_ scene: PublicWorldStressBenchmark.Scene, device: MTLDevice, warmupFrames: Int,
                                   measuredFrames: Int) async throws -> PublicWorldStressReport {
        let report = try await PublicWorldStressBenchmark.run(device: device, scene: scene,
            renderSize: renderSize(for: scene), warmupFrames: warmupFrames, measuredFrames: measuredFrames,
            progress: { _, _ in })
        guard report.safetyPassed else {
            throw PerfGuardError.unsafeRun("\(scene.name): nieudane klatki=\(report.failedFrames), wartości nieskończone=\(report.nonFiniteFrames), odczyty konturów=\(report.contourCPUReadbacks)")
        }
        return report
    }

    /// Jeden przebieg sceny; zwraca p95 pełnej klatki.
    @MainActor
    static func measureScene(_ scene: PublicWorldStressBenchmark.Scene, device: MTLDevice, warmupFrames: Int,
                             measuredFrames: Int) async throws -> Double {
        try await measureSceneReport(scene, device: device, warmupFrames: warmupFrames,
            measuredFrames: measuredFrames).p95Milliseconds
    }

    /// Składowe czasu klatki z raportu przebiegu: p95 każdej składowej (kodowanie, oczekiwanie i inne).
    static func components(of report: PublicWorldStressReport) -> StageComponents {
        StageComponents(hostPreparationMilliseconds: report.hostPreparationP95Milliseconds,
            hostEncodingMilliseconds: report.hostEncodingP95Milliseconds,
            hostWaitingMilliseconds: report.hostWaitingP95Milliseconds,
            hostPublicationMilliseconds: report.hostPublicationP95Milliseconds,
            hostNonGPUMilliseconds: report.hostNonGPUP95Milliseconds, gpuMilliseconds: report.gpuP95Milliseconds,
            gpuPhysicsMilliseconds: report.gpuPhysicsP95Milliseconds)
    }

    /// Jeden przebieg sceny o `bubbleCount` bańkach; zwraca p95 czasu klatki po stronie CPU (poza czasem GPU),
    /// czyli przygotowania wejścia, kodowania i publikacji kroku.
    ///
    /// To górne ograniczenie kosztu przygotowania i publikacji kroku: `hostNonGPUP95Milliseconds` to czas klatki
    /// minus czas GPU, więc zawiera też kodowanie renderu i oczekiwanie na GPU, których kryterium nie obejmuje.
    /// Wystarcza, bo strażnik ma wykryć wzrost kosztu hosta; jeśli górne ograniczenie mieści się w limicie,
    /// to koszt samego przygotowania i publikacji (składnik tej sumy) tym bardziej.
    @MainActor
    static func measureHostCPU(device: MTLDevice, bubbleCount: Int, warmupFrames: Int,
                               measuredFrames: Int) async throws -> Double {
        let report = try await PublicWorldStressBenchmark.run(device: device, bubbleCount: bubbleCount,
            warmupFrames: warmupFrames, measuredFrames: measuredFrames, progress: { _, _ in })
        guard report.safetyPassed else {
            throw PerfGuardError.unsafeRun("\(bubbleCount) baniek: nieudane klatki=\(report.failedFrames), wartości nieskończone=\(report.nonFiniteFrames), odczyty konturów=\(report.contourCPUReadbacks)")
        }
        return report.hostNonGPUP95Milliseconds
    }

    /// Scena benchmarku dla nazwy sceny strażnika.
    static func benchmarkScene(named scene: String) throws -> PublicWorldStressBenchmark.Scene {
        switch scene {
        case "stress-300": return .stress300
        case "mixed": return .mixed
        case "decals": return .decals
        case "acceptance": return .acceptance
        default: throw PerfGuardOptions.ParseError.invalidArgument(scene)
        }
    }

    @MainActor
    static func measure(scene: String, device: MTLDevice, options: PerfGuardOptions) async throws -> Double {
        try await measureScene(benchmarkScene(named: scene), device: device, warmupFrames: options.warmupFrames,
            measuredFrames: options.measuredFrames)
    }

    /// Sceny, które mierzy dany przebieg: `--scene`, scena prognozy przy `--calibrate` i `--check-prediction`,
    /// inaczej wszystkie.
    static func scenesToMeasure(_ options: PerfGuardOptions) -> [String] {
        if let scene = options.scene { return [scene] }
        if options.calibrateReportPath != nil || options.checkPredictionReportPath != nil { return [predictionScene] }
        return scenes
    }

    /// Skalowanie 600/300 dotyczy całego zestawu; pomiar jednej sceny je pomija.
    static func measuresScaling(_ options: PerfGuardOptions) -> Bool { scenesToMeasure(options) == scenes }

    private static func git(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw PerfGuardError.gitFailed(arguments.joined(separator: " ")) }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Linie składowych i prognozy po pomiarze sceny `acceptance`; `--calibrate` zapisuje plik kalibracji,
    /// `--check-prediction` porównuje prognozę z raportem iPhone'a. Zwraca kod wyjścia wyznaczony przez prognozę
    /// (`nil`, gdy prognoza go nie zmienia) i linie do wypisania.
    static func predictionLines(options: PerfGuardOptions, mac: StageComponents,
                                calibrationURL: URL, commit: () throws -> String) throws -> (lines: [String], exitCode: Int32?) {
        var lines = [DevicePrediction.stagesLine(scene: predictionScene, mac: mac)]
        var calibration = try DeviceCalibration.loadIfPresent(from: calibrationURL)
        if let path = options.calibrateReportPath {
            let report = try DevicePrediction.parse(report: String(contentsOfFile: path, encoding: .utf8))
            calibration = try DevicePrediction.calibrate(iPhone: report, mac: mac, commit: commit())
            try calibration?.write(to: calibrationURL)
            lines.append("Zapisano kalibrację iPhone'a X w \(calibrationURL.path) (commit \(calibration?.commit ?? ""))")
        }
        guard let calibration else {
            if options.checkPredictionReportPath != nil { throw PerfGuardError.missingCalibration(calibrationURL.path) }
            return (lines, nil)
        }
        lines.append(DevicePrediction.predictLine(scene: predictionScene,
            try DevicePrediction.predict(calibration: calibration, mac: mac)))
        guard let path = options.checkPredictionReportPath else { return (lines, nil) }
        let check = try DevicePrediction.checkPrediction(report: String(contentsOfFile: path, encoding: .utf8),
            calibration: calibration, mac: mac)
        lines.append(check.text)
        return (lines, check.exitCode)
    }

    /// Punkt wejścia z `main.swift`; zwraca kod wyjścia procesu.
    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        do {
            let options = try PerfGuardOptions.parse(arguments)
            guard let device = MTLCreateSystemDefaultDevice() else {
                print("Brak urządzenia Metal")
                return 2
            }
            let url = URL(fileURLWithPath: options.baselinePath)
            let existing = try PerfGuardBaseline.loadIfPresent(from: url)
            if let scene = options.recordScene {
                var runs: [Double] = []
                for _ in 0..<options.runs { runs.append(try await measure(scene: scene, device: device, options: options)) }
                let base = existing?.device == device.name ? existing! : PerfGuardBaseline(device: device.name, scenes: [:])
                let stamp = ISO8601DateFormatter().string(from: Date())
                try base.recording(scene: scene, runs: runs, recordedAt: stamp, note: options.note).write(to: url)
                print("Zapisano punkt odniesienia \(scene): p95 \(String(format: "%.4f", median(runs))) ms (\(device.name)) w \(options.baselinePath)")
                return 0
            }
            let stages = StageCollector()
            var scalingMeasure: (@MainActor (Int) async throws -> Double)?
            if measuresScaling(options) {
                scalingMeasure = { count in
                    try await measureHostCPU(device: device, bubbleCount: count,
                        warmupFrames: options.warmupFrames, measuredFrames: options.measuredFrames)
                }
            }
            let report = try await check(scenes: scenesToMeasure(options), baseline: existing, device: device.name,
                runs: options.runs, injectedSlowdown: options.injectedSlowdown,
                measure: { scene in
                    let result = try await measureSceneReport(benchmarkScene(named: scene), device: device,
                        warmupFrames: options.warmupFrames, measuredFrames: options.measuredFrames)
                    if scene == predictionScene { stages.values.append(components(of: result)) }
                    return result.p95Milliseconds
                },
                scalingMeasure: scalingMeasure)
            print(report.text)
            var exitCode: Int32 = report.passed ? 0 : 1
            if !stages.values.isEmpty {
                if options.calibrateReportPath != nil, try !git(["status", "--porcelain", "--untracked-files=no"]).isEmpty {
                    print("UWAGA: drzewo robocze ma niezatwierdzone zmiany; kalibracja ma pochodzić z jednego commitu")
                }
                let prediction = try predictionLines(options: options, mac: StageComponents.median(of: stages.values),
                    calibrationURL: URL(fileURLWithPath: calibrationPath), commit: { try git(["rev-parse", "HEAD"]) })
                prediction.lines.forEach { print($0) }
                if let code = prediction.exitCode { exitCode = code }
            }
            return exitCode
        } catch {
            print("Błąd strażnika: \(error)")
            print(PerfGuardOptions.usage)
            return 2
        }
    }
}

/// Składowe z kolejnych przebiegów sceny prognozy.
@MainActor
private final class StageCollector {
    var values: [StageComponents] = []
}

enum PerfGuardError: Error {
    case unsafeRun(String)
    case gitFailed(String)
    case missingCalibration(String)
}

private extension Optional {
    func asyncMap<T>(_ transform: (Wrapped) async throws -> T) async rethrows -> T? {
        switch self {
        case .some(let value): return try await transform(value)
        case .none: return nil
        }
    }
}
