import BubblePhysicsMetalRender
import Foundation

/// Składowe czasu klatki w milisekundach: mediany p95 z przebiegów na Macu albo wartości z raportu iPhone'a.
/// Nazwy pól są kluczami pliku kalibracji (`jq .mac.hostPreparationMilliseconds`).
struct StageComponents: Codable, Equatable {
    var hostPreparationMilliseconds: Double
    var hostEncodingMilliseconds: Double
    var hostWaitingMilliseconds: Double
    var hostPublicationMilliseconds: Double
    var hostNonGPUMilliseconds: Double
    var gpuMilliseconds: Double
    var gpuPhysicsMilliseconds: Double

    /// Mediana każdego pola osobno.
    static func median(of values: [StageComponents]) -> StageComponents {
        func field(_ keyPath: KeyPath<StageComponents, Double>) -> Double {
            PerfGuard.median(values.map { $0[keyPath: keyPath] })
        }
        return StageComponents(hostPreparationMilliseconds: field(\.hostPreparationMilliseconds),
            hostEncodingMilliseconds: field(\.hostEncodingMilliseconds),
            hostWaitingMilliseconds: field(\.hostWaitingMilliseconds),
            hostPublicationMilliseconds: field(\.hostPublicationMilliseconds),
            hostNonGPUMilliseconds: field(\.hostNonGPUMilliseconds), gpuMilliseconds: field(\.gpuMilliseconds),
            gpuPhysicsMilliseconds: field(\.gpuPhysicsMilliseconds))
    }
}

/// Raport benchmarku z urządzenia (linie `klucz=wartość`) po sparsowaniu.
struct DeviceReport: Equatable {
    /// Commit z nagłówka raportu (`Mierzony kod: …`), jeśli jest.
    var commit: String?
    var p95Milliseconds: Double
    var components: StageComponents
}

/// Plik `docs/benchmarks/iphone-x-calibration.json`: składowe iPhone'a i Maca z jednego commitu oraz mnożniki.
struct DeviceCalibration: Codable, Equatable {
    struct Ratios: Codable, Equatable {
        var cpu: Double
        var physics: Double
    }
    var commit: String
    var iphone: StageComponents
    var mac: StageComponents
    var ratios: Ratios
    /// Koszt renderu GPU na iPhonie: `gpu_p95_ms − gpu_physics_p95_ms` z raportu kalibracyjnego.
    var iphoneRenderMilliseconds: Double

    static func load(from url: URL) throws -> DeviceCalibration {
        try JSONDecoder().decode(DeviceCalibration.self, from: Data(contentsOf: url))
    }

    static func loadIfPresent(from url: URL) throws -> DeviceCalibration? {
        FileManager.default.fileExists(atPath: url.path) ? try load(from: url) : nil
    }

    func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try (encoder.encode(self) + Data("\n".utf8)).write(to: url, options: .atomic)
    }
}

/// Prognoza p95 klatki iPhone'a X ze składowych Maca.
struct PredictedFrame: Equatable {
    var p95Milliseconds: Double
    var cpuMilliseconds: Double
    var physicsMilliseconds: Double
    var renderMilliseconds: Double
}

/// Wynik porównania prognozy z raportem z urządzenia.
struct PredictionCheck: Equatable {
    var predictedMilliseconds: Double
    var reportedMilliseconds: Double
    /// `(prognoza − raport) / raport`, ze znakiem.
    var errorFraction: Double
    var passed: Bool
    var exitCode: Int32 { passed ? 0 : 1 }
    /// Linia `PREDICTION_ERROR`; zaczyna się od liczb, które plik raportu cytuje.
    var text: String {
        "PREDICTION_ERROR p95=\(DevicePrediction.format(reportedMilliseconds)) predicted=\(DevicePrediction.format(predictedMilliseconds)) error=\(String(format: "%.1f", errorFraction * 100))% limit=\(String(format: "%.1f", DevicePrediction.errorTolerance * 100))% \(passed ? "PASS" : "FAIL")"
    }
}

enum DevicePredictionError: Error, Equatable {
    case missingLine(String)
    case invalidValue(line: String, value: String)
    case nonPositiveComponent(String)
    case commitMismatch(report: String, current: String)
    /// Raport z urządzenia bez nagłówka `Mierzony kod:`; kalibracja wymaga jednego, znanego commitu.
    case missingCommit
}

enum DevicePrediction {
    /// Cel prognozy: zapas na błąd modelu pod bramką urządzenia.
    static let targetMilliseconds = 15.0
    static let gateMilliseconds = PublicWorldStressBenchmark.acceptanceGateMilliseconds
    /// Największy dopuszczalny błąd prognozy względem raportu z urządzenia.
    static let errorTolerance = 0.10

    /// Klucze raportu, które prognoza czyta, w kolejności sprawdzania brakujących linii.
    private static let requiredKeys = ["p95_ms", "gpu_p95_ms", "host_non_gpu_p95_ms", "host_preparation_p95_ms",
        "host_encoding_p95_ms", "host_waiting_p95_ms", "host_publication_p95_ms", "gpu_physics_p95_ms"]

    static func format(_ value: Double) -> String { String(format: "%.4f", value) }

    /// Czyta linie `klucz=wartość` (kilka na linię, rozdzielone `;`); klucze muszą pasować w całości,
    /// więc `gpu_p95_ms` nie jest mylone z `p95_ms`.
    static func parse(report: String) throws -> DeviceReport {
        var values: [String: String] = [:]
        for line in report.split(whereSeparator: \.isNewline) {
            for part in line.split(separator: ";") {
                let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if pair.count == 2, requiredKeys.contains(pair[0]), values[pair[0]] == nil { values[pair[0]] = pair[1] }
            }
        }
        func number(_ key: String) throws -> Double {
            guard let text = values[key] else { throw DevicePredictionError.missingLine(key) }
            guard let value = Double(text), value.isFinite, value >= 0 else {
                throw DevicePredictionError.invalidValue(line: key, value: text)
            }
            return value
        }
        var parsed: [String: Double] = [:]
        for key in requiredKeys { parsed[key] = try number(key) }
        return DeviceReport(commit: commit(in: report), p95Milliseconds: parsed["p95_ms"]!,
            components: StageComponents(hostPreparationMilliseconds: parsed["host_preparation_p95_ms"]!,
                hostEncodingMilliseconds: parsed["host_encoding_p95_ms"]!,
                hostWaitingMilliseconds: parsed["host_waiting_p95_ms"]!,
                hostPublicationMilliseconds: parsed["host_publication_p95_ms"]!,
                hostNonGPUMilliseconds: parsed["host_non_gpu_p95_ms"]!,
                gpuMilliseconds: parsed["gpu_p95_ms"]!, gpuPhysicsMilliseconds: parsed["gpu_physics_p95_ms"]!))
    }

    /// Commit z nagłówka raportu: `Mierzony kod: `<sha>``.
    private static func commit(in report: String) -> String? {
        guard let marker = report.range(of: "Mierzony kod: `") else { return nil }
        let sha = report[marker.upperBound...].prefix { $0.isHexDigit }
        return sha.isEmpty ? nil : String(sha)
    }

    /// Ten sam commit w pełnej albo skróconej postaci.
    private static func sameCommit(_ lhs: String, _ rhs: String) -> Bool {
        let a = lhs.lowercased(), b = rhs.lowercased()
        return !a.isEmpty && !b.isEmpty && (a.hasPrefix(b) || b.hasPrefix(a))
    }

    static func calibrate(iPhone: DeviceReport, mac: StageComponents, commit: String) throws -> DeviceCalibration {
        guard let reported = iPhone.commit else { throw DevicePredictionError.missingCommit }
        guard sameCommit(reported, commit) else {
            throw DevicePredictionError.commitMismatch(report: reported, current: commit)
        }
        guard mac.hostNonGPUMilliseconds.isFinite, mac.hostNonGPUMilliseconds > 0 else {
            throw DevicePredictionError.nonPositiveComponent("hostNonGPUMilliseconds")
        }
        guard mac.gpuPhysicsMilliseconds.isFinite, mac.gpuPhysicsMilliseconds > 0 else {
            throw DevicePredictionError.nonPositiveComponent("gpuPhysicsMilliseconds")
        }
        let phone = iPhone.components
        return DeviceCalibration(commit: commit, iphone: phone, mac: mac,
            ratios: .init(cpu: phone.hostNonGPUMilliseconds / mac.hostNonGPUMilliseconds,
                          physics: phone.gpuPhysicsMilliseconds / mac.gpuPhysicsMilliseconds),
            iphoneRenderMilliseconds: phone.gpuMilliseconds - phone.gpuPhysicsMilliseconds)
    }

    /// `r_cpu · cpu_Mac + r_fiz · fizyka_GPU_Mac + render_GPU_iPhone`; koszt renderu pochodzi z kalibracji.
    static func predict(calibration: DeviceCalibration, mac: StageComponents) -> PredictedFrame {
        let cpu = calibration.ratios.cpu * mac.hostNonGPUMilliseconds
        let physics = calibration.ratios.physics * mac.gpuPhysicsMilliseconds
        let render = calibration.iphoneRenderMilliseconds
        return PredictedFrame(p95Milliseconds: cpu + physics + render, cpuMilliseconds: cpu,
            physicsMilliseconds: physics, renderMilliseconds: render)
    }

    static func check(predictedP95: Double, reportedP95: Double) throws -> PredictionCheck {
        guard reportedP95.isFinite, reportedP95 > 0 else {
            throw DevicePredictionError.invalidValue(line: "p95_ms", value: "\(reportedP95)")
        }
        guard predictedP95.isFinite else {
            throw DevicePredictionError.invalidValue(line: "predicted", value: "\(predictedP95)")
        }
        let error = (predictedP95 - reportedP95) / reportedP95
        return PredictionCheck(predictedMilliseconds: predictedP95, reportedMilliseconds: reportedP95,
            errorFraction: error, passed: abs(error) <= errorTolerance + 1e-9)
    }

    static func checkPrediction(report: String, calibration: DeviceCalibration,
                                mac: StageComponents) throws -> PredictionCheck {
        let parsed = try parse(report: report)
        return try check(predictedP95: predict(calibration: calibration, mac: mac).p95Milliseconds,
                         reportedP95: parsed.p95Milliseconds)
    }

    /// Linia `STAGES` strażnika.
    static func stagesLine(scene: String, mac: StageComponents) -> String {
        "STAGES \(scene): host_preparation=\(format(mac.hostPreparationMilliseconds)) host_encoding=\(format(mac.hostEncodingMilliseconds)) host_waiting=\(format(mac.hostWaitingMilliseconds)) host_publication=\(format(mac.hostPublicationMilliseconds)) host_non_gpu=\(format(mac.hostNonGPUMilliseconds)) gpu=\(format(mac.gpuMilliseconds)) gpu_physics=\(format(mac.gpuPhysicsMilliseconds))"
    }

    /// Linia `PREDICT` strażnika.
    static func predictLine(scene: String, _ prediction: PredictedFrame) -> String {
        "PREDICT iphone-x \(scene): p95=\(format(prediction.p95Milliseconds)) cpu=\(format(prediction.cpuMilliseconds)) physics=\(format(prediction.physicsMilliseconds)) render=\(format(prediction.renderMilliseconds)) target=\(String(format: "%.2f", targetMilliseconds)) gate=\(String(format: "%.2f", gateMilliseconds))"
    }
}
