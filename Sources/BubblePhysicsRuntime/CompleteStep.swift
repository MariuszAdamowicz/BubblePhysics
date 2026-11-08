import BubblePhysicsModel

/// Granica atomowej publikacji. Implementacja zwraca dopiero kompletny stan i zdarzenia.
/// Przy błędzie nie wolno zmienić wcześniej opublikowanego stanu ani jego zasobów.
@MainActor
package protocol CompleteStepper: AnyObject {
    func validate(_ change: StagedWorldChange) throws
    func completeStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep
}
extension CompleteStepper {
    package func validate(_ change: StagedWorldChange) throws {}
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
    package init(state: RuntimeState, events: [WorldEvent] = [],
                 eventOverflow: WorldEventOverflow = WorldEventOverflow(), driveFeedback: [DriveFeedback] = [],
                 contactCandidateOverflowCount: Int = 0, maximumContactCandidatesPerObject: Int = 0) {
        self.state = state; self.events = events
        self.eventOverflow = eventOverflow
        self.driveFeedback = driveFeedback
        self.contactCandidateOverflowCount = contactCandidateOverflowCount
        self.maximumContactCandidatesPerObject = maximumContactCandidatesPerObject
    }
}
