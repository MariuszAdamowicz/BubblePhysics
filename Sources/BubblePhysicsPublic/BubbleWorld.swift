import Foundation
import Metal
import BubblePhysicsModel
import BubblePhysicsRuntime
import BubblePhysicsNativeMetal

package struct BubbleWorldRenderItem {
    package let shader: RenderShader
    package let channels: [ParameterID: Float]
}

package struct BubbleWorldRenderState {
    package let handoff: NativeMetalRenderHandoff
    package let items: [BubbleWorldRenderItem?]
}

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
    private var pendingRenderState: BubbleWorldRenderState?

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
            isPaused: isPaused, isAdvancing: isAdvancing, lastAdvanceIssue: lastAdvanceIssue,
            eventOverflow: lastFrame.eventOverflow)
    }

    /// Renderer widzi tylko opublikowany uchwyt i kanały prezentacyjne.
    package var renderState: BubbleWorldRenderState? {
        if let pendingRenderState { return pendingRenderState }
        guard let handoff = (stepper as? NativeCompleteStepper)?.publishedRenderHandoff else { return nil }
        return makeRenderState(handoff, from: state)
    }

    private func makeRenderState(_ handoff: NativeMetalRenderHandoff,
                                 from source: RuntimeState) -> BubbleWorldRenderState {
        let items: [BubbleWorldRenderItem?] = handoff.bubbleIDs.map { id in
            guard let object = source.objects[id], case .bubble(let bubble) = object.descriptor,
                  let style = source.renderStyles[bubble.renderStyleID] else { return nil }
            return BubbleWorldRenderItem(shader: style.shader,
                channels: style.resolvedChannels(overrides: object.presentation))
        }
        return BubbleWorldRenderState(handoff: handoff, items: items)
    }

    /// CPU adapter/debug. Wywołanie kopiuje opublikowane kontury z pamięci GPU.
    public func debugContourSnapshot() -> [ObjectID: [WorldPoint]] {
        (stepper as? NativeCompleteStepper)?.publishedRenderHandoff?.debugContourSnapshot() ?? [:]
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
        await advanceImpl(by: seconds, commandBuffer: nil, encodeRender: nil)
    }

    /// Koduje krok fizyki, następnie render do tego samego bufora aplikacji;
    /// po jego ukończeniu publikuje wynik. Jeden bufor obejmuje najwyżej jeden krok.
    /// Drawable należy prezentować dopiero po zwrocie ukończonej klatki bez błędu.
    /// Gdy czas nie wystarcza na krok, bufor pozostaje niezatwierdzony.
    public func advance(by seconds: TimeInterval, commandBuffer: MTLCommandBuffer,
                        encodeRender: @escaping () throws -> Void) async -> WorldFrame {
        await advanceImpl(by: seconds, commandBuffer: commandBuffer, encodeRender: encodeRender)
    }

    private func advanceImpl(by seconds: TimeInterval, commandBuffer: MTLCommandBuffer?,
                             encodeRender: (() throws -> Void)?) async -> WorldFrame {
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
        var droppedEvents = 0
        let stepLimit = commandBuffer == nil ? clock.maximumStepsPerAdvance : 1
        while !isPaused && clock.canStep && stepsInLastAdvance < stepLimit {
            guard !Task.isCancelled else {
                lastAdvanceIssue = .advanceCancelled
                break
            }
            let transactionCount = pending.count
            let batch = TransactionStager.stageBatch(pending, against: state, validate: stepper.validate)
            do {
                let complete: CompletedRuntimeStep
                if let commandBuffer, let encodeRender,
                   let native = stepper as? NativeCompleteStepper {
                    complete = try await native.completeStep(batch, duration: clock.fixedTimeStep,
                        commandBuffer: commandBuffer) { [self] handoff in
                        pendingRenderState = makeRenderState(handoff, from: batch.state)
                        defer { pendingRenderState = nil }
                        try encodeRender()
                    }
                } else {
                    complete = try await stepper.completeStep(batch, duration: clock.fixedTimeStep)
                }
                // Scena bez ciał nie uruchamia solvera, ale bufor wywołującego
                // nadal musi zawierać ukończony render przed publikacją kroku.
                if let commandBuffer, let encodeRender, commandBuffer.status == .notEnqueued {
                    if let handoff = (stepper as? NativeCompleteStepper)?.publishedRenderHandoff {
                        pendingRenderState = makeRenderState(handoff, from: batch.state)
                    }
                    defer { pendingRenderState = nil }
                    try encodeRender()
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        commandBuffer.addCompletedHandler { completed in
                            if completed.status == .completed { continuation.resume() }
                            else { continuation.resume(throwing: WorldRenderCommandError.failed) }
                        }
                        commandBuffer.commit()
                    }
                }
                // W czasie await można dopisać transakcje lub włączyć pauzę.
                // Dopiero tutaj publikujemy kandydat i zdejmujemy wyłącznie jego prefiks kolejki.
                state = complete.state
                pending.removeFirst(transactionCount)
                clock.completeStep()
                stepsInLastAdvance += 1
                receipts += batch.frame.transactionReceipts
                events += batch.frame.events + complete.events
                droppedEvents += complete.eventOverflow.droppedCount
                lastFrame = WorldFrame(stepIndex: clock.completedSteps, simulationTime: clock.simulationTime,
                    transactionReceipts: receipts, events: events,
                    eventOverflow: WorldEventOverflow(droppedCount: droppedEvents), driveFeedback: complete.driveFeedback)
            } catch {
                lastAdvanceIssue = error is CancellationError ? .advanceCancelled : .stepFailed
                break
            }
        }
        return lastFrame
    }
}

private enum WorldRenderCommandError: Error { case failed }
