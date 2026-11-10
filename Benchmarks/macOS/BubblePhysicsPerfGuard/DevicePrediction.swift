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
        StageComponents(hostPreparationMilliseconds: 0, hostEncodingMilliseconds: 0, hostWaitingMilliseconds: 0,
            hostPublicationMilliseconds: 0, hostNonGPUMilliseconds: 0, gpuMilliseconds: 0, gpuPhysicsMilliseconds: 0)
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

    static func load(from url: URL) throws -> DeviceCalibration { throw DevicePredictionError.notImplemented }

    func write(to url: URL) throws { throw DevicePredictionError.notImplemented }
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
    var text: String { "" }
}

enum DevicePredictionError: Error, Equatable {
    case notImplemented
    case missingLine(String)
    case invalidValue(line: String, value: String)
    case nonPositiveComponent(String)
    case commitMismatch(report: String, current: String)
}

enum DevicePrediction {
    /// Cel prognozy: zapas na błąd modelu pod bramką urządzenia.
    static let targetMilliseconds = 15.0
    static let gateMilliseconds = 16.67
    /// Największy dopuszczalny błąd prognozy względem raportu z urządzenia.
    static let errorTolerance = 0.10

    static func parse(report: String) throws -> DeviceReport { throw DevicePredictionError.notImplemented }

    static func calibrate(iPhone: DeviceReport, mac: StageComponents, commit: String) throws -> DeviceCalibration {
        throw DevicePredictionError.notImplemented
    }

    static func predict(calibration: DeviceCalibration, mac: StageComponents) throws -> PredictedFrame {
        throw DevicePredictionError.notImplemented
    }

    static func check(predictedP95: Double, reportedP95: Double) throws -> PredictionCheck {
        throw DevicePredictionError.notImplemented
    }

    static func checkPrediction(report: String, calibration: DeviceCalibration,
                                mac: StageComponents) throws -> PredictionCheck {
        throw DevicePredictionError.notImplemented
    }

    /// Linia `STAGES` strażnika.
    static func stagesLine(scene: String, mac: StageComponents) -> String { "" }

    /// Linia `PREDICT` strażnika.
    static func predictLine(scene: String, _ prediction: PredictedFrame) -> String { "" }
}
