import Foundation
import Darwin
import Metal
import BubblePhysicsReference
import BubblePhysicsReferenceMetal

private let usage = "Użycie: BubblePhysicsReferenceBench [--scene interactive-24|stress-300] [--backend cpu|metal] [--limits 4,8,12,16] [--warmup 30] [--measured 300] [--diagnostics]\n--diagnostics: szczegółowy profil GPU dodaje narzut hosta; nie mieszaj z pomiarem akceptacyjnym."

private enum CLIError: Error, CustomStringConvertible {
    case invalidArgument(String)
    var description: String {
        switch self { case .invalidArgument(let value): return "Nieprawidłowy argument: \(value)" }
    }
}

private func configuration(arguments: [String]) throws -> ReferenceBenchmarkMatrixConfiguration {
    var result = ReferenceBenchmarkMatrixConfiguration(scene: .interactive24, warmupSteps: 30, measuredSteps: 300)
    var index = 0
    while index < arguments.count {
        let option = arguments[index]
        if option == "--diagnostics" {
            result.gpuDiagnosticsEnabled = true
            index += 1
            continue
        }
        guard index + 1 < arguments.count else { throw CLIError.invalidArgument(option) }
        let value = arguments[index + 1]
        switch option {
        case "--scene":
            guard let scene = ReferenceConvergenceScene(rawValue: value) else { throw CLIError.invalidArgument(value) }
            result.scene = scene
        case "--backend":
            guard let backend = ReferenceSimulationBackend(rawValue: value) else { throw CLIError.invalidArgument(value) }
            result.backend = backend
        case "--limits":
            let values = value.split(separator: ",", omittingEmptySubsequences: false)
            let limits = values.compactMap { Int($0) }
            guard !limits.isEmpty, limits.count == values.count,
                  limits.allSatisfy({ [4, 8, 12, 16].contains($0) }) else { throw CLIError.invalidArgument(value) }
            result.iterationLimits = limits
        case "--warmup", "--measured":
            guard let count = Int(value), count >= 0 else { throw CLIError.invalidArgument(value) }
            if option == "--warmup" { result.warmupSteps = count } else { result.measuredSteps = count }
        default: throw CLIError.invalidArgument(option)
        }
        index += 2
    }
    return result
}

private func deviceName() -> String {
    var size = 0
    guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else {
        return "macOS Mac (model unavailable); GPU: \(MTLCreateSystemDefaultDevice()?.name ?? "unavailable")"
    }
    var model = [CChar](repeating: 0, count: size)
    let status = sysctlbyname("hw.model", &model, &size, nil, 0)
    return "macOS \(status == 0 ? String(cString: model) : "Mac (model unavailable)"); GPU: \(MTLCreateSystemDefaultDevice()?.name ?? "unavailable")"
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments == ["--help"] {
    print(usage)
} else {
    do {
        let report = try await ReferenceMetalBenchmarkRunner.measure(configuration: configuration(arguments: arguments))
        print(report.plainText(deviceName: deviceName(), systemVersion: ProcessInfo.processInfo.operatingSystemVersionString))
    } catch {
        FileHandle.standardError.write(Data("\(error)\n\(usage)\n".utf8))
        exit(1)
    }
}
