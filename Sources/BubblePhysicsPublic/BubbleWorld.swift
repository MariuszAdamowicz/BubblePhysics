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
    package let handoff: NativeMetalRenderHandoff?
    package let items: [BubbleWorldRenderItem?]
    package let shapes: [BubbleWorldRenderShape]
}

package struct BubbleWorldRenderShape {
    /// Pierścień we współrzędnych lokalnych obiektu. Triangulacja zależy tylko od niego,
    /// bo przekształcenie sztywne zachowuje orientację i zawieranie.
    package let localVertices: [WorldPoint]
    package let vertices: [WorldPoint]
    package let item: BubbleWorldRenderItem
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
    /// Narastający licznik odrzuconych kandydatów kontaktu i maksimum na obiekt z ostatniego ukończonego kroku.
    private var contactCandidateOverflow = 0
    private var maximumContactCandidatesPerObject = 0
    private var pendingRenderState: BubbleWorldRenderState?
    /// Stan końcowy „zawiódł”: ustawiony raz, nigdy nie czyszczony.
    private var failureReason: WorldFailureReason?
    private var lastRejectionReason: WorldRejectionReason?

    public convenience init(configuration: WorldConfiguration,
                            device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        self.init(configuration: configuration, stepper: try NativeCompleteStepper(device: device))
    }

    /// Konstruktor wyłącznie dla diagnostycznego harnessu; limit nie jest parametrem API gry.
    package static func makeBenchmarkWorld(configuration: WorldConfiguration, device: MTLDevice,
                                           solverIterationLimit: Int) throws -> BubbleWorld {
        try BubbleWorld(configuration: configuration, stepper: NativeCompleteStepper(device: device,
            configuration: NativeMetalConfiguration(solverIterationCount: solverIterationLimit)))
    }

    package var benchmarkTelemetry: NativeMetalFrameTelemetry? {
        (stepper as? NativeCompleteStepper)?.publishedTelemetry
    }
    package var benchmarkFrameProfile: NativeMetalFrameProfile? {
        (stepper as? NativeCompleteStepper)?.publishedFrameProfile
    }
    package var benchmarkContourCPUReadbackCount: Int {
        (stepper as? NativeCompleteStepper)?.publishedContourCPUReadbackCount ?? 0
    }

    internal init(configuration: WorldConfiguration, stepper: any CompleteStepper) {
        self.configuration = configuration
        self.state = RuntimeState(configuration: configuration)
        self.clock = FixedStepDriver(fixedTimeStep: configuration.fixedTimeStep,
                                     maximumBacklog: configuration.maximumBacklog)
        self.stepper = stepper
    }

    public var diagnostics: WorldDiagnostics {
        WorldDiagnostics(backlogSeconds: clock.backlogSeconds,
            consecutiveBackloggedAdvances: clock.consecutiveBackloggedAdvances,
            discardedBacklogSeconds: clock.discardedBacklogSeconds,
            stepsInLastAdvance: stepsInLastAdvance, pendingTransactionCount: pending.count,
            isPaused: isPaused, isAdvancing: isAdvancing, lastAdvanceIssue: lastAdvanceIssue,
            eventOverflow: lastFrame.eventOverflow,
            contactCandidateOverflow: contactCandidateOverflow,
            maximumContactCandidatesPerObject: maximumContactCandidatesPerObject,
            failureReason: failureReason, lastRejectionReason: lastRejectionReason)
    }

    /// Stały limit k kandydatów kontaktu na obiekt, wspólny dla wszystkich rodzajów par.
    package static var contactCandidateLimit: Int { NativeMetalSolver.candidateLimitPerObject }

    /// Renderer widzi tylko opublikowany uchwyt i kanały prezentacyjne.
    package var renderState: BubbleWorldRenderState? {
        if let pendingRenderState { return pendingRenderState }
        guard clock.completedSteps > 0 else { return nil }
        return makeRenderState((stepper as? NativeCompleteStepper)?.publishedRenderHandoff, from: state)
    }

    private func makeRenderState(_ handoff: NativeMetalRenderHandoff?,
                                 from source: RuntimeState) -> BubbleWorldRenderState {
        let items: [BubbleWorldRenderItem?] = (handoff?.bubbleIDs ?? []).map { id in
            guard let object = source.objects[id], case .bubble(let bubble) = object.descriptor,
                  let style = source.renderStyles[bubble.renderStyleID] else { return nil }
            return BubbleWorldRenderItem(shader: style.shader,
                channels: style.resolvedChannels(overrides: object.presentation))
        }
        let shapes = source.objects.sorted { $0.key.rawValue < $1.key.rawValue }.compactMap { _, object -> BubbleWorldRenderShape? in
            guard let style = source.renderStyles[object.style] else { return nil }
            let ring: [WorldPoint]
            switch object.descriptor {
            case .bubble: return nil
            case .rigidBody(let body): ring = Self.rigidRing(body.shape)
            case .sensor(let sensor): ring = Self.rangeRing(sensor.geometry)
            case .forceField(let field): ring = Self.rangeRing(field.geometry)
            }
            let cosine = cos(object.rotation), sine = sin(object.rotation)
            let vertices = ring.map { point in
                WorldPoint(object.position.x + point.x * cosine - point.y * sine,
                           object.position.y + point.x * sine + point.y * cosine)
            }
            return BubbleWorldRenderShape(localVertices: ring, vertices: vertices,
                item: BubbleWorldRenderItem(shader: style.shader,
                    channels: style.resolvedChannels(overrides: object.presentation)))
        }
        return BubbleWorldRenderState(handoff: handoff, items: items, shapes: shapes)
    }

    /// Obrys bryły do rysowania jako pierścień; koło i kapsuła to wielokąty o 48 wierzchołkach na pełny obrót.
    private static func rigidRing(_ shape: RigidShape) -> [WorldPoint] {
        switch shape {
        case .polygon(let geometry): return geometry.vertices
        case .circle(let radius):
            return (0..<48).map { index in
                let angle = Float(index) * 2 * Float.pi / 48
                return WorldPoint(radius * cos(angle), radius * sin(angle))
            }
        case .capsule(let halfLength, let radius):
            // Prawe półkole od −90° do 90°, potem lewe od 90° do 270°, środki na końcach osi.
            let arc = 24
            let right = (0...arc).map { index -> WorldPoint in
                let angle = -Float.pi / 2 + Float(index) * Float.pi / Float(arc)
                return WorldPoint(halfLength + radius * cos(angle), radius * sin(angle))
            }
            let left = (0...arc).map { index -> WorldPoint in
                let angle = Float.pi / 2 + Float(index) * Float.pi / Float(arc)
                return WorldPoint(-halfLength + radius * cos(angle), radius * sin(angle))
            }
            return right + left
        }
    }

    private static func rangeRing(_ geometry: RangeGeometry) -> [WorldPoint] {
        switch geometry.shape {
        case .polygon(let polygon): return polygon.vertices
        case .circle(let radius):
            return (0..<48).map { index in
                let angle = Float(index) * 2 * Float.pi / 48
                return WorldPoint(radius * cos(angle), radius * sin(angle))
            }
        }
    }

    /// CPU adapter/debug. Wywołanie kopiuje opublikowane kontury z pamięci GPU.
    public func debugContourSnapshot() -> [ObjectID: [WorldPoint]] {
        let snapshot = (stepper as? NativeCompleteStepper)?.publishedRenderHandoff?.debugContourSnapshot() ?? [:]
        return snapshot.filter { id, _ in
            guard let object = state.objects[id] else { return false }
            if case .bubble = object.descriptor { return true }
            return false
        }
    }

    // Zaślepki do zadań 39 i 41.
    package var queryIndexBuildCount: Int { 0 }
    package var pendingHitTestCount: Int { 0 }
    public func objects(at point: WorldPoint, filter: CollisionFilter? = nil) -> [ObjectID] { [] }
    public func objects(in rectangle: WorldRectangle, filter: CollisionFilter? = nil) -> [ObjectID] { [] }
    public func objects(inCircle center: WorldPoint, radius: Float, filter: CollisionFilter? = nil) -> [ObjectID] { [] }
    public func raycast(from start: WorldPoint, to end: WorldPoint, filter: CollisionFilter? = nil) -> RaycastHit? { nil }
    public func hitTest(_ point: WorldPoint) async -> ObjectID? { nil }

    /// Token jest unikalny w obrębie świata. Walidacja nastąpi na granicy kroku.
    @discardableResult
    public func submit(_ transaction: WorldTransaction) -> TransactionToken {
        let token = TransactionToken(rawValue: nextToken)
        nextToken += 1
        // W stanie „zawiódł” token jest unikalny, ale żadna klatka go nie potwierdzi.
        guard failureReason == nil else { return token }
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
        // Stan końcowy wygrywa z pauzą i z krokiem.
        guard failureReason == nil else {
            lastAdvanceIssue = .worldFailed
            return lastFrame
        }
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
        // Każdy błąd domknięcia gry wychodzi z kroku jako `GameRenderError`, więc nie da się go pomylić z błędem solvera,
        // także wtedy, gdy sam jest typem błędu solvera.
        let encode: (() throws -> Void)? = encodeRender.map { game in
            { do { try game() } catch { throw GameRenderError(underlying: error) } }
        }
        var receipts: [TransactionReceipt] = []
        var events: [WorldEvent] = []
        var droppedEvents = 0
        let stepLimit = commandBuffer == nil ? clock.maximumStepsPerAdvance : 1
        stepLoop: while !isPaused && clock.canStep && stepsInLastAdvance < stepLimit {
            guard !Task.isCancelled else {
                lastAdvanceIssue = .advanceCancelled
                break
            }
            let transactionCount = pending.count
            let batch = TransactionStager.stageBatch(pending, against: state, validate: stepper.validate)
            do {
                let beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)? = encode.map { encode in
                    { [self] handoff, prepared in
                        pendingRenderState = makeRenderState(handoff, from: prepared)
                        defer { pendingRenderState = nil }
                        try encode()
                    }
                }
                let complete = try await stepper.completeStep(batch, duration: clock.fixedTimeStep, hitTests: [],
                    commandBuffer: commandBuffer, beforeCommit: beforeCommit)
                // Scena bez ciał nie uruchamia solvera, ale bufor wywołującego
                // nadal musi zawierać ukończony render przed publikacją kroku.
                if let commandBuffer, let encode, commandBuffer.status == .notEnqueued {
                    pendingRenderState = makeRenderState(nil, from: complete.state)
                    defer { pendingRenderState = nil }
                    try encode()
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
                contactCandidateOverflow += complete.contactCandidateOverflowCount
                maximumContactCandidatesPerObject = complete.maximumContactCandidatesPerObject
                lastFrame = WorldFrame(stepIndex: clock.completedSteps, simulationTime: clock.simulationTime,
                    transactionReceipts: receipts, events: events,
                    eventOverflow: WorldEventOverflow(droppedCount: droppedEvents), driveFeedback: complete.driveFeedback,
                    objects: state.publishedObjectStates())
                stepper.didPublish(complete)
            } catch {
                switch Self.outcome(of: error) {
                case .cancelled:
                    lastAdvanceIssue = .advanceCancelled
                case .frameRejected:
                    lastAdvanceIssue = .frameRejected
                    lastRejectionReason = .frameEncoding
                case .stepRejected(let reason):
                    lastAdvanceIssue = .stepFailed
                    lastRejectionReason = reason
                case .failed(let reason):
                    failureReason = reason
                    pending.removeAll()
                    lastAdvanceIssue = .worldFailed
                }
                break stepLoop
            }
        }
        return lastFrame
    }

    private enum StepOutcome {
        case cancelled, frameRejected
        case stepRejected(WorldRejectionReason)
        case failed(WorldFailureReason)
    }

    /// Skutek błędu kroku: tylko błąd wykonania GPU i NaN/±∞ kończą świat; błąd gry odrzuca klatkę;
    /// reszta błędów solvera odrzuca krok (kolejka czeka, powód w diagnostyce).
    private static func outcome(of error: Error) -> StepOutcome {
        if error is CancellationError { return .cancelled }
        if error is GameRenderError { return .frameRejected }
        if error is WorldRenderCommandError { return .failed(.commandExecutionFailed) }
        if let failure = error as? NativeMetalSafetyFailure { return outcome(of: failure.reason) }
        if let reason = error as? NativeMetalWorldError { return outcome(of: reason) }
        if let solver = error as? NativeMetalSolverError {
            switch solver {
            case .commandFailed: return .failed(.commandExecutionFailed)
            case .invalidSnapshot: return .stepRejected(.invalidSnapshot)
            default: return .stepRejected(.unexpected)
            }
        }
        return .stepRejected(.unexpected)
    }

    private static func outcome(of reason: NativeMetalWorldError) -> StepOutcome {
        switch reason {
        case .nonFinite: return .failed(.nonFiniteValues)
        case .guardFailure: return .stepRejected(.solverGuard)
        case .invalidFrame: return .stepRejected(.invalidFrame)
        case .frameInFlight: return .stepRejected(.frameInFlight)
        case .unavailable: return .stepRejected(.unexpected)
        }
    }
}

/// Błąd zgłoszony przez domknięcie `encodeRender` gry albo przez kodowanie renderu.
private struct GameRenderError: Error { let underlying: Error }

private enum WorldRenderCommandError: Error { case failed }
