import Foundation
import Metal
import BubblePhysicsModel
import BubblePhysicsRuntime

/// Jedyny właściciel świata i kolejki transakcji. Publikuje wyłącznie ukończone kroki.
@MainActor
public final class BubbleWorld {
    public let configuration: WorldConfiguration
    private var state: RuntimeState
    private var clock: FixedStepDriver
    private let stepper: any CompleteStepper
    private var pending: [PendingTransaction] = []
    private var nextToken: UInt64 = 1
    private var lastFrame = WorldFrame(transactionReceipts: [], events: [])
    private var isPaused = false
    private var isAdvancing = false
    private var stepsInLastAdvance = 0
    private var lastAdvanceIssue: WorldAdvanceIssue?

    public convenience init(configuration: WorldConfiguration,
                            device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        self.init(configuration: configuration, stepper: try NativeCompleteStepper(device: device))
    }

    internal init(configuration: WorldConfiguration, stepper: any CompleteStepper) {
        self.configuration = configuration
        self.state = RuntimeState(configuration: configuration)
        self.clock = FixedStepDriver(fixedTimeStep: configuration.fixedTimeStep)
        self.stepper = stepper
    }

    public var diagnostics: WorldDiagnostics {
        WorldDiagnostics(backlogSeconds: clock.backlogSeconds,
            consecutiveBackloggedAdvances: clock.consecutiveBackloggedAdvances,
            stepsInLastAdvance: stepsInLastAdvance, pendingTransactionCount: pending.count,
            isPaused: isPaused, isAdvancing: isAdvancing, lastAdvanceIssue: lastAdvanceIssue)
    }

    /// Token jest unikalny w obrębie świata. Walidacja nastąpi na granicy kroku.
    @discardableResult
    public func submit(_ transaction: WorldTransaction) -> TransactionToken {
        let token = TransactionToken(rawValue: nextToken)
        nextToken += 1
        pending.append(PendingTransaction(token: token, transaction: transaction))
        return token
    }

    /// Pauza zachowuje kolejkę i istniejący akumulator. Czas przekazany w pauzie jest ignorowany.
    /// Rozpoczęty krok może się ukończyć; kolejny poczeka na resume.
    public func pause() { isPaused = true }
    public func resume() { isPaused = false }

    /// Przyjmuje skończony, nieujemny czas prezentacji. Zero pozwala opróżnić backlog.
    /// Jedno wywołanie wykonuje ograniczoną liczbę kroków; cały nadmiar zostaje w diagnostyce.
    /// Brak ukończonego kroku (także błąd) zwraca ostatnią kompletną klatkę.
    public func advance(by seconds: TimeInterval) async -> WorldFrame {
        guard !isAdvancing else {
            lastAdvanceIssue = .advanceAlreadyInProgress
            return lastFrame
        }
        stepsInLastAdvance = 0
        lastAdvanceIssue = nil
        guard seconds.isFinite, seconds >= 0 else {
            lastAdvanceIssue = .invalidTimeDelta
            return lastFrame
        }
        guard !isPaused else { return lastFrame }
        guard clock.accumulate(seconds) else {
            lastAdvanceIssue = .timeAccumulatorOverflow
            return lastFrame
        }
        isAdvancing = true
        defer { isAdvancing = false; clock.finishAdvance() }
        var receipts: [TransactionReceipt] = []
        var events: [WorldEvent] = []
        while !isPaused && clock.canStep && stepsInLastAdvance < clock.maximumStepsPerAdvance {
            guard !Task.isCancelled else {
                lastAdvanceIssue = .advanceCancelled
                break
            }
            let transactionCount = pending.count
            let batch = TransactionStager.stageBatch(pending, against: state, validate: stepper.validate)
            do {
                let complete = try await stepper.completeStep(batch, duration: clock.fixedTimeStep)
                // W czasie await można dopisać transakcje lub włączyć pauzę.
                // Dopiero tutaj publikujemy kandydat i zdejmujemy wyłącznie jego prefiks kolejki.
                state = complete.state
                pending.removeFirst(transactionCount)
                clock.completeStep()
                stepsInLastAdvance += 1
                receipts += batch.frame.transactionReceipts
                events += batch.frame.events + complete.events
                lastFrame = WorldFrame(stepIndex: clock.completedSteps, simulationTime: clock.simulationTime,
                    transactionReceipts: receipts, events: events)
            } catch {
                lastAdvanceIssue = error is CancellationError ? .advanceCancelled : .stepFailed
                break
            }
        }
        return lastFrame
    }
}
