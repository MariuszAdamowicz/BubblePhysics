@_exported import BubblePhysicsReference
import Foundation
import Metal

/// Immutable diagnostic snapshots avoid retaining Metal objects or arbitrary
/// NSError userInfo values across the completion-handler/actor boundary.
public struct ReferenceMetalEncoderFailure: Equatable, Sendable {
    public let label: String
    public let executionStatus: Int
    public let debugSignposts: [String]

    public init(label: String, executionStatus: Int, debugSignposts: [String] = []) {
        self.label = label
        self.executionStatus = executionStatus
        self.debugSignposts = debugSignposts
    }
}

public struct ReferenceMetalGPUFailure: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Classification: String, Sendable {
        case ordinary, hang, timeout, accessRevoked, submissionsIgnored
    }

    public let stage: String
    public let scenarioStep: Int
    public let reason: String
    public let commandBufferErrorCode: Int?
    public let errorDomain: String?
    public let errorUserInfo: [String: String]
    public let commandBufferStatus: Int?
    public let encoderFailures: [ReferenceMetalEncoderFailure]
    public let classification: Classification
    public var isFatal: Bool { classification != .ordinary }

    public init(stage: String, scenarioStep: Int, error: NSError?, commandBufferStatus: Int? = nil) {
        let encoderFailures = (error?.userInfo[MTLCommandBufferEncoderInfoErrorKey] as? [MTLCommandBufferEncoderInfo] ?? []).map {
            ReferenceMetalEncoderFailure(label: $0.label, executionStatus: $0.errorState.rawValue,
                                         debugSignposts: $0.debugSignposts)
        }
        self.stage = encoderFailures.first { $0.executionStatus == MTLCommandEncoderErrorState.faulted.rawValue }?.label ?? stage
        self.scenarioStep = scenarioStep
        reason = error?.localizedDescription ?? "Metal command failed"
        commandBufferErrorCode = error?.code
        errorDomain = error?.domain
        errorUserInfo = error?.userInfo.mapValues { String(describing: $0) } ?? [:]
        self.commandBufferStatus = commandBufferStatus
        self.encoderFailures = encoderFailures
        let diagnostics = ([reason] + errorUserInfo.values).joined(separator: " ").lowercased()
        if error?.domain == MTLCommandBufferErrorDomain && error?.code == Int(MTLCommandBufferError.timeout.rawValue) {
            classification = .timeout
        } else if error?.domain == MTLCommandBufferErrorDomain && error?.code == Int(MTLCommandBufferError.accessRevoked.rawValue) {
            classification = .accessRevoked
        } else if diagnostics.contains("kiogpucommandbuffercallbackerrorhang") {
            classification = .hang
        } else if diagnostics.contains("submissionsignored") {
            classification = .submissionsIgnored
        } else {
            classification = .ordinary
        }
    }

    public var description: String {
        let info = errorUserInfo.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        let encoders = encoderFailures.map { "\($0.label):\($0.executionStatus)" }.joined(separator: ", ")
        return "GPU \(classification.rawValue) stage=\(stage) step=\(scenarioStep) domain=\(errorDomain ?? "unknown") code=\(commandBufferErrorCode.map(String.init) ?? "unknown") status=\(commandBufferStatus.map(String.init) ?? "unknown") reason=\(reason) userInfo={\(info)} encoders=[\(encoders)]"
    }
}

public struct ReferenceMetalFrameTelemetry: Equatable, Sendable {
    public let backend: ReferenceSimulationBackend
    public let frameMilliseconds: Double
    public let gpuMilliseconds: Double
    public let finalResidual: Float
    public let newtonIterations: Int
    public let pcgIterations: Int
    public let didOverflow: Bool
    public let didEncounterNonFinite: Bool
    public let fallbackReason: String?
    public let gpuFailure: ReferenceMetalGPUFailure?

    public init(
        backend: ReferenceSimulationBackend = .cpu,
        frameMilliseconds: Double = 0,
        gpuMilliseconds: Double = 0,
        finalResidual: Float = 0,
        newtonIterations: Int = 0,
        pcgIterations: Int = 0,
        didOverflow: Bool = false,
        didEncounterNonFinite: Bool = false,
        fallbackReason: String? = nil,
        gpuFailure: ReferenceMetalGPUFailure? = nil
    ) {
        self.backend = backend
        self.frameMilliseconds = frameMilliseconds
        self.gpuMilliseconds = gpuMilliseconds
        self.finalResidual = finalResidual
        self.newtonIterations = newtonIterations
        self.pcgIterations = pcgIterations
        self.didOverflow = didOverflow
        self.didEncounterNonFinite = didEncounterNonFinite
        self.fallbackReason = fallbackReason
        self.gpuFailure = gpuFailure
    }
}
