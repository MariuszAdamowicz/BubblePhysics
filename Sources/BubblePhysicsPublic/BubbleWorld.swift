import Foundation
import Metal
import BubblePhysicsAssets
import BubblePhysicsModel
import BubblePhysicsRuntime
import BubblePhysicsNativeMetal

/// Lista rysowania opublikowanego stanu: tło i warstwy rosnąco, w warstwie bańki, potem bryły, każda grupa rosnąco po
/// `ObjectID`. Czujniki i pola sił nie mają materiału renderu, więc ich tu nie ma.
package struct BubbleWorldRenderState {
    package let handoff: NativeMetalRenderHandoff?
    /// Tekstura tła rozciągnięta na region symulacji; `nil`, gdy tła nie ma.
    package let background: TextureID?
    package let region: WorldRectangle
    package let layers: [BubbleWorldRenderLayer]
    /// Waga stanu t w obrazie między t−1 i t (1 = sam stan t).
    package let interpolation: Float
    /// Obiekty rysowane bez interpolacji w tej klatce (pojawiły się albo zawinęły w ostatnim kroku).
    package let snapped: Set<ObjectID>
}

package struct BubbleWorldRenderLayer {
    package let layer: Int32
    package let bubbles: [BubbleWorldRenderBubble]
    package let shapes: [BubbleWorldRenderShape]
}

package struct BubbleWorldRenderBubble {
    package let id: ObjectID
    package let materialID: RenderMaterialID
    package let material: RenderMaterial
    /// Naklejka rysowana po wszystkich bańkach warstwy; kotwicę i promień odniesienia (efektywny) renderer bierze z uchwytu.
    package let decal: Decal?
}

package struct BubbleWorldRenderShape {
    package let id: ObjectID
    package let materialID: RenderMaterialID
    package let material: RenderMaterial
    /// Pierścień we współrzędnych lokalnych obiektu. Triangulacja zależy tylko od niego, bo przekształcenie sztywne zachowuje
    /// orientację i zawieranie. Pozę (z interpolacją t−1 → t) nakłada shader z rekordu bryły w uchwycie.
    package let localVertices: [WorldPoint]
    /// Naklejka rysowana po wszystkich bryłach warstwy; jej kotwica to początek układu lokalnego bryły (`position`), obraca się z bryłą.
    package let decal: Decal?
    /// Promień okręgu opisanego na kształcie wokół kotwicy (promień odniesienia naklejki).
    package let referenceRadius: Float
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
    /// Pauza ręczna (`pause()`/`resume()`) i automatyczna (aplikacja w tle) są niezależne; świat stoi, gdy działa którakolwiek.
    private var isManuallyPaused = false
    private var isPausedInBackground = false
    private var isPaused: Bool { isManuallyPaused || isPausedInBackground }
    /// Trzyma źródło zdarzeń cyklu życia przy życiu; uchwyty źródła nie trzymają świata.
    private let lifecycle: LifecycleEventSource?
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
    private var didRenderLastAdvance = false
    /// Obiekty ostatniego opublikowanego kroku, które rysują się bez interpolacji.
    private var snappedObjects: Set<ObjectID> = []
    private struct PendingHitTest {
        let id: UInt64
        let point: WorldPoint
        let continuation: CheckedContinuation<ObjectID?, Never>
    }
    private var pendingHitTests: [PendingHitTest] = []
    private var nextHitTestID: UInt64 = 1
    private var queryIndexCache: QueryIndex?
    private var queryIndexBuilds = 0

    /// Rejestr tekstur świata: gra rejestruje w nim obrazy poza klatką, a transakcje wskazują je przez `TextureID`.
    /// `nil` tylko wtedy, gdy świat nie ma urządzenia.
    public let assets: AssetRegistry?

    /// `assets == nil` daje pusty rejestr urządzenia świata. Rejestr innego urządzenia (albo rejestr przy świecie bez
    /// urządzenia) to `AssetError.deviceMismatch`.
    public convenience init(configuration: WorldConfiguration,
                            device: MTLDevice? = MTLCreateSystemDefaultDevice(),
                            assets: AssetRegistry? = nil,
                            lifecycle: LifecycleEventSource? = nil) throws {
        let registry: AssetRegistry?
        if let assets {
            guard let device, device.registryID == assets.deviceRegistryID else { throw AssetError.deviceMismatch }
            registry = assets
        } else {
            registry = device.map { AssetRegistry(device: $0) }
        }
        self.init(configuration: configuration, stepper: try NativeCompleteStepper(device: device), assets: registry,
                  lifecycle: lifecycle)
    }

    /// Konstruktor wyłącznie dla diagnostycznego harnessu; limit nie jest parametrem API gry.
    package static func makeBenchmarkWorld(configuration: WorldConfiguration, device: MTLDevice,
                                           solverIterationLimit: Int) throws -> BubbleWorld {
        try BubbleWorld(configuration: configuration, stepper: NativeCompleteStepper(device: device,
            configuration: NativeMetalConfiguration(solverIterationCount: solverIterationLimit)),
            assets: AssetRegistry(device: device))
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

    internal init(configuration: WorldConfiguration, stepper: any CompleteStepper, assets: AssetRegistry? = nil,
                  lifecycle: LifecycleEventSource? = nil) {
        self.configuration = configuration
        self.assets = assets
        self.state = RuntimeState(configuration: configuration)
        self.clock = FixedStepDriver(fixedTimeStep: configuration.fixedTimeStep,
                                     maximumBacklog: configuration.maximumBacklog)
        self.stepper = stepper
        self.lifecycle = configuration.automaticPause ? (lifecycle ?? defaultLifecycleEventSource()) : nil
        self.lifecycle?.willEnterBackground = { [weak self] in self?.isPausedInBackground = true }
        self.lifecycle?.didBecomeActive = { [weak self] in
            guard let self, isPausedInBackground else { return }
            isPausedInBackground = false
            // Czas spędzony w tle nie jest czasem gry: pierwszy przyrost po powrocie jest odrzucany.
            clock.discardNextAdvance()
        }
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
            failureReason: failureReason, lastRejectionReason: lastRejectionReason,
            didRenderLastAdvance: didRenderLastAdvance)
    }

    /// Stały limit k kandydatów kontaktu na obiekt, wspólny dla wszystkich rodzajów par.
    package static var contactCandidateLimit: Int { NativeMetalSolver.candidateLimitPerObject }

    /// Renderer widzi tylko opublikowany uchwyt i listę rysowania; czujniki i pola sił nie są rysowane.
    package var renderState: BubbleWorldRenderState? {
        if let pendingRenderState { return pendingRenderState }
        guard clock.completedSteps > 0 else { return nil }
        return makeRenderState((stepper as? NativeCompleteStepper)?.publishedRenderHandoff, from: state, interpolation: 1,
                               snapped: snappedObjects)
    }

    /// Lista rysowania z `source`: warstwy rosnąco, w nich bańki i bryły rosnąco po `ObjectID`. Obiekt bez materiału renderu
    /// (czujnik, pole sił) nie jest rysowany.
    private func makeRenderState(_ handoff: NativeMetalRenderHandoff?, from source: RuntimeState, interpolation: Float,
                                 snapped: Set<ObjectID>) -> BubbleWorldRenderState {
        var bubbles: [Int32: [BubbleWorldRenderBubble]] = [:], shapes: [Int32: [BubbleWorldRenderShape]] = [:]
        for (id, object) in source.objects.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
            guard let materialID = object.renderMaterialID, let material = source.renderMaterials[materialID] else { continue }
            switch object.descriptor {
            case .bubble:
                bubbles[object.layer, default: []].append(
                    BubbleWorldRenderBubble(id: id, materialID: materialID, material: material, decal: object.decal))
            case .rigidBody(let body):
                shapes[object.layer, default: []].append(BubbleWorldRenderShape(id: id, materialID: materialID,
                    material: material, localVertices: Self.rigidRing(body.shape), decal: object.decal,
                    referenceRadius: object.decal == nil ? 0 : Self.circumscribedRadius(body.shape)))
            case .sensor, .forceField: continue
            }
        }
        let layers = Set(bubbles.keys).union(shapes.keys).sorted().map {
            BubbleWorldRenderLayer(layer: $0, bubbles: bubbles[$0] ?? [], shapes: shapes[$0] ?? [])
        }
        return BubbleWorldRenderState(handoff: handoff, background: source.background,
                                      region: source.configuration.simulationRegion, layers: layers,
                                      interpolation: interpolation, snapped: snapped)
    }

    /// Promień okręgu opisanego na kształcie wokół początku układu lokalnego (kotwicy naklejki).
    private static func circumscribedRadius(_ shape: RigidShape) -> Float {
        switch shape {
        case .polygon(let geometry): return geometry.vertices.map { ($0 * $0).sum().squareRoot() }.max() ?? 0
        case .circle(let radius): return radius
        case .capsule(let halfLength, let radius): return halfLength + radius
        }
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

    /// CPU adapter/debug. Wywołanie kopiuje opublikowane kontury z pamięci GPU.
    public func debugContourSnapshot() -> [ObjectID: [WorldPoint]] {
        let snapshot = (stepper as? NativeCompleteStepper)?.publishedRenderHandoff?.debugContourSnapshot() ?? [:]
        return snapshot.filter { id, _ in
            guard let object = state.objects[id] else { return false }
            if case .bubble = object.descriptor { return true }
            return false
        }
    }

    // MARK: zapytania synchroniczne

    /// Indeks zapytań budowany leniwie z opublikowanego stanu; każda publikacja go unieważnia, więc powstaje
    /// najwyżej raz na publikację.
    private func index() -> QueryIndex {
        if let queryIndexCache { return queryIndexCache }
        let built = QueryIndex(state: state)
        queryIndexCache = built
        queryIndexBuilds += 1
        return built
    }

    /// Ile razy zbudowano indeks zapytań; szew testów „najwyżej raz na publikację”.
    package var queryIndexBuildCount: Int { queryIndexBuilds }

    /// Obiekty (bańki i bryły) zawierające punkt, rosnąco po `ObjectID`. Odpowiedź dotyczy ostatnio opublikowanego stanu.
    /// Bryły są sprawdzane dokładnie, a bańka jako koło o efektywnym promieniu; dokładny kontur bańki daje `hitTest`.
    /// Filtr działa jak filtr obiektu: wynik to obiekty, z którymi taki obiekt by kolidował; `nil` nie zawęża.
    public func objects(at point: WorldPoint, filter: CollisionFilter? = nil) -> [ObjectID] {
        index().objects(at: point, filter: filter)
    }

    /// Obiekty przecinające prostokąt, rosnąco po `ObjectID`.
    public func objects(in rectangle: WorldRectangle, filter: CollisionFilter? = nil) -> [ObjectID] {
        index().objects(in: rectangle, filter: filter)
    }

    /// Obiekty przecinające koło o danym środku i promieniu (nieujemnym i skończonym), rosnąco po `ObjectID`.
    public func objects(inCircle center: WorldPoint, radius: Float, filter: CollisionFilter? = nil) -> [ObjectID] {
        index().objects(inCircle: center, radius: radius, filter: filter)
    }

    /// Pierwsze trafienie na odcinku od `start` do `end`; `nil`, gdy odcinek niczego nie trafia albo ma wartości nieskończone.
    public func raycast(from start: WorldPoint, to end: WorldPoint, filter: CollisionFilter? = nil) -> RaycastHit? {
        index().raycast(from: start, to: end, filter: filter)
    }

    // MARK: hit-test asynchroniczny

    /// Liczba zapytań `hitTest` czekających na krok; szew testów.
    package var pendingHitTestCount: Int { pendingHitTests.count }

    /// Dokładny hit-test punktu: zdeformowane kontury baniek i dokładne kształty brył, policzony na GPU na stanie
    /// następnego ukończonego kroku (obiekt usunięty przed tym krokiem nie bierze udziału). Zwraca najwyżej jeden
    /// obiekt: przy nakładaniu wygrywa najwyższa warstwa, a przy tej samej warstwie największy `ObjectID`.
    /// Warstwy pojawią się w slice 5; do tego czasu każdy obiekt leży w warstwie 0, więc rozstrzyga `ObjectID`.
    /// W pauzie zapytanie czeka na wznowienie; przy odrzuconym kroku lub klatce czeka na następny krok.
    /// Punkt nieskończony, stan „zawiódł” i anulowanie zadania dają `nil` od razu. Zawieszone wywołanie trzyma świat
    /// przy życiu do publikacji kroku albo anulowania, więc gra porzucająca świat anuluje swoje zadanie.
    public func hitTest(_ point: WorldPoint) async -> ObjectID? {
        guard point.x.isFinite, point.y.isFinite, failureReason == nil, !Task.isCancelled else { return nil }
        let id = nextHitTestID
        nextHitTestID += 1
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<ObjectID?, Never>) in
                pendingHitTests.append(PendingHitTest(id: id, point: point, continuation: continuation))
            }
        } onCancel: {
            // Obsługa anulowania działa poza MainActor; słaba referencja nie przedłuża życia świata.
            Task { @MainActor [weak self] in self?.cancelHitTest(id) }
        }
    }

    private func cancelHitTest(_ id: UInt64) {
        guard let index = pendingHitTests.firstIndex(where: { $0.id == id }) else { return }
        pendingHitTests.remove(at: index).continuation.resume(returning: nil)
    }

    /// Wznawia zapytania przekazane krokowi; zapytania anulowane w międzyczasie już ich nie ma, a późniejsze zostają.
    private func resolveHitTests(_ handled: [PendingHitTest], with results: [ObjectID?]) {
        for (position, entry) in handled.enumerated() {
            guard let index = pendingHitTests.firstIndex(where: { $0.id == entry.id }) else { continue }
            pendingHitTests.remove(at: index).continuation.resume(returning: position < results.count ? results[position] : nil)
        }
    }

    private func dropHitTests() {
        let dropped = pendingHitTests
        pendingHitTests.removeAll()
        for entry in dropped { entry.continuation.resume(returning: nil) }
    }

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
    /// Pauza automatyczna w tle (`WorldConfiguration.automaticPause`) jest od niej niezależna.
    public func pause() { isManuallyPaused = true }
    public func resume() { isManuallyPaused = false }

    /// Przyjmuje skończony, nieujemny czas prezentacji. Zero pozwala opróżnić backlog.
    /// Jedno wywołanie wykonuje ograniczoną liczbę kroków; cały nadmiar zostaje w diagnostyce.
    /// Brak ukończonego kroku (także błąd) zwraca ostatnią kompletną klatkę.
    public func advance(by seconds: TimeInterval) async -> WorldFrame {
        await advanceImpl(by: seconds, commandBuffer: nil, encodeRender: nil)
    }

    /// Koduje krok fizyki, następnie render do tego samego bufora aplikacji;
    /// po jego ukończeniu publikuje wynik. Jeden bufor obejmuje najwyżej jeden krok.
    /// Drawable należy prezentować tylko przy `diagnostics.didRenderLastAdvance`.
    /// Gdy czas nie wystarcza na krok, `encodeRender` rysuje opublikowany stan z interpolacją t−1 → t, bufor jest
    /// zatwierdzany i ukończony, ale nic nie jest publikowane. Bufor zostaje niezatwierdzony w pauzie, w stanie „zawiódł”
    /// i po odrzuceniu klatki.
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
        didRenderLastAdvance = false
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
            // Punkty przekazane temu krokowi; zapytania złożone w czasie kroku czekają na następny.
            let hitTestBatch = pendingHitTests
            let batch = TransactionStager.stageBatch(pending, against: state, validate: stepper.validate,
                textureExists: { [assets] texture in assets?.contains(texture) ?? false },
                glyphLookup: { [assets] source in assets?.glyphLookup(source) })
            // Obiekty z partii znamy przed krokiem; zawinięcia dopiero po nim, więc w klatce z krokiem ich nie ma. Zawiniętą bańkę
            // albo bryłę rysuje bez interpolacji shader (flaga rekordu).
            let appeared = batch.appearedObjectIDs
            do {
                let beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)? = encode.map { encode in
                    { [self] handoff, prepared in
                        let alpha = Float(clock.interpolationFractionAfterNextStep)
                        pendingRenderState = makeRenderState(handoff, from: prepared, interpolation: alpha, snapped: appeared)
                        defer { pendingRenderState = nil }
                        try encode()
                    }
                }
                let complete = try await stepper.completeStep(batch, duration: clock.fixedTimeStep, hitTests: hitTestBatch.map(\.point),
                    commandBuffer: commandBuffer, beforeCommit: beforeCommit)
                // Scena bez ciał nie uruchamia solvera, ale bufor wywołującego
                // nadal musi zawierać ukończony render przed publikacją kroku.
                if let commandBuffer, let encode, commandBuffer.status == .notEnqueued {
                    let alpha = Float(clock.interpolationFractionAfterNextStep)
                    pendingRenderState = makeRenderState(nil, from: complete.state, interpolation: alpha,
                                                         snapped: complete.snappedObjectIDs)
                    defer { pendingRenderState = nil }
                    try encode()
                    try await commitAndWait(commandBuffer)
                }
                // W czasie await można dopisać transakcje lub włączyć pauzę.
                // Dopiero tutaj publikujemy kandydat i zdejmujemy wyłącznie jego prefiks kolejki.
                snappedObjects = complete.snappedObjectIDs
                state = complete.state
                queryIndexCache = nil
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
                resolveHitTests(hitTestBatch, with: complete.hitTestResults)
                if commandBuffer != nil { didRenderLastAdvance = true }
            } catch {
                handleAdvanceError(error)
                break stepLoop
            }
        }
        // Klatka bez kroku (np. 120 Hz przy kroku 1/60): rysuje opublikowany stan z interpolacją i zatwierdza bufor, ale
        // niczego nie publikuje, więc `lastFrame` zostaje bez zmian.
        if stepsInLastAdvance == 0, lastAdvanceIssue == nil, failureReason == nil, !isPaused,
           let commandBuffer, let encode, commandBuffer.status == .notEnqueued {
            do {
                let alpha = Float(clock.interpolationFraction)
                pendingRenderState = makeRenderState((stepper as? NativeCompleteStepper)?.publishedRenderHandoff, from: state,
                    interpolation: alpha, snapped: snappedObjects)
                defer { pendingRenderState = nil }
                try encode()
                try await commitAndWait(commandBuffer)
                didRenderLastAdvance = true
            } catch {
                handleAdvanceError(error)
            }
        }
        return lastFrame
    }

    /// Zatwierdza bufor gry i czeka na jego ukończenie; status inny niż `completed` to błąd wykonania (stan „zawiódł”).
    private func commitAndWait(_ commandBuffer: MTLCommandBuffer) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            commandBuffer.addCompletedHandler { completed in
                if completed.status == .completed { continuation.resume() }
                else { continuation.resume(throwing: WorldRenderCommandError.failed) }
            }
            commandBuffer.commit()
        }
    }

    private func handleAdvanceError(_ error: Error) {
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
            dropHitTests()
            lastAdvanceIssue = .worldFailed
        }
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
