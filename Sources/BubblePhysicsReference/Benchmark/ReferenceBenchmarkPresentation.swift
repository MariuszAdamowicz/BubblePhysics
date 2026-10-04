import Combine
import Foundation

public enum ReferenceBenchmarkMode: String, Sendable, CaseIterable {
    case single
    case matrix
}

@MainActor
public final class ReferenceBenchmarkPresentation: ObservableObject {
    public typealias Runner = @Sendable (
        ReferenceBenchmarkMatrixConfiguration,
        @escaping @Sendable (ReferenceBenchmarkProgress) async -> Void
    ) async throws -> ReferenceBenchmarkMatrixReport

    @Published public var scene: ReferenceConvergenceScene = .interactive24
    @Published public var mode: ReferenceBenchmarkMode = .matrix
    @Published public var selectedLimit = 4
    @Published public private(set) var progress = 0.0
    @Published public private(set) var reportText: String?
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var isRunning = false

    private let runner: Runner
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0

    public init(runner: @escaping Runner = { configuration, progress in
        try await ReferenceBenchmarkMatrixRunner.measure(
            configuration: configuration,
            progress: progress
        )
    }) {
        self.runner = runner
    }

    public func start(
        deviceName: String,
        systemVersion: String,
        warmupSteps: Int = 30,
        measuredSteps: Int = 300
    ) {
        invalidateCurrentRun()
        let currentGeneration = generation
        let limits = mode == .matrix ? [4, 8, 12, 16] : [selectedLimit]
        let configuration = ReferenceBenchmarkMatrixConfiguration(
            scene: scene,
            warmupSteps: warmupSteps,
            measuredSteps: measuredSteps,
            iterationLimits: limits
        )
        progress = 0
        reportText = nil
        errorMessage = nil
        isRunning = true

        task = Task { [weak self, runner] in
            guard let self else { return }
            do {
                let report = try await runner(configuration) { value in
                    await self.publish(value, generation: currentGeneration)
                }
                guard self.generation == currentGeneration, !Task.isCancelled else { return }
                self.reportText = report.plainText(deviceName: deviceName, systemVersion: systemVersion)
                self.progress = 1
                self.isRunning = false
                self.task = nil
            } catch is CancellationError {
                guard self.generation == currentGeneration else { return }
                self.isRunning = false
                self.task = nil
            } catch {
                guard self.generation == currentGeneration else { return }
                self.errorMessage = String(describing: error)
                self.isRunning = false
                self.task = nil
            }
        }
    }

    public func stop() {
        invalidateCurrentRun()
        isRunning = false
    }

    private func invalidateCurrentRun() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    private func publish(_ value: ReferenceBenchmarkProgress, generation expected: UInt64) {
        guard generation == expected else { return }
        progress = value.totalSteps == 0
            ? 1
            : min(1, max(0, Double(value.completedSteps) / Double(value.totalSteps)))
    }
}
