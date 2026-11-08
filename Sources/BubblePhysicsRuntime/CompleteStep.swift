import BubblePhysicsModel
import BubblePhysicsNativeMetal
import Metal

/// Granica atomowej publikacji. Implementacja zwraca dopiero kompletny stan i zdarzenia.
/// Przy błędzie nie wolno zmienić wcześniej opublikowanego stanu ani jego zasobów, a stan własny steppera
/// (historia kontaktów) zmienia się dopiero w `didPublish`, które świat woła po publikacji klatki.
@MainActor
package protocol CompleteStepper: AnyObject {
    func validate(_ change: StagedWorldChange) throws
    /// Jedna metoda kroku. Z buforem poleceń stepper koduje krok GPU i woła `beforeCommit` przed zatwierdzeniem
    /// (`handoff` jest nil, gdy kroku GPU nie ma); bez bufora tylko liczy krok. `hitTests` są punktami
    /// oczekujących zapytań .
    func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                      commandBuffer: MTLCommandBuffer?,
                      beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep
    /// Wołane po publikacji kroku; odrzucony krok lub klatka go nie wywołują.
    func didPublish(_ step: CompletedRuntimeStep)
}
extension CompleteStepper {
    package func validate(_ change: StagedWorldChange) throws {}
    package func didPublish(_ step: CompletedRuntimeStep) {}

    /// Krok bez bufora poleceń i zapytań, od razu opublikowany: skrót dla testów, które prowadzą stepper bez świata.
    package func completePublishedStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep {
        let step = try await completeStep(batch, duration: duration, hitTests: [], commandBuffer: nil, beforeCommit: nil)
        didPublish(step)
        return step
    }
}

package struct CompletedRuntimeStep {
    package let state: RuntimeState
    package let events: [WorldEvent]
    package let eventOverflow: WorldEventOverflow
    package let driveFeedback: [DriveFeedback]
    /// Pary kandydatów kontaktu odrzucone w tym kroku przez limit k (etap 2).
    package let contactCandidateOverflowCount: Int
    /// Największa liczba kandydatów na obiekt w tym kroku (etap 2).
    package let maximumContactCandidatesPerObject: Int
    /// Wynik hit-testu dla każdego punktu z `hitTests` kroku, w tej samej kolejności; `nil` to puste miejsce.
    /// Pusta tablica (stepper bez zapytań) oznacza `nil` dla każdego punktu.
    package let hitTestResults: [ObjectID?]
    package init(state: RuntimeState, events: [WorldEvent] = [],
                 eventOverflow: WorldEventOverflow = WorldEventOverflow(), driveFeedback: [DriveFeedback] = [],
                 contactCandidateOverflowCount: Int = 0, maximumContactCandidatesPerObject: Int = 0,
                 hitTestResults: [ObjectID?] = []) {
        self.hitTestResults = hitTestResults
        self.state = state; self.events = events
        self.eventOverflow = eventOverflow
        self.driveFeedback = driveFeedback
        self.contactCandidateOverflowCount = contactCandidateOverflowCount
        self.maximumContactCandidatesPerObject = maximumContactCandidatesPerObject
    }
}
