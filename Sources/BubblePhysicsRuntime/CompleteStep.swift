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
    package init(state: RuntimeState, events: [WorldEvent] = [],
                 eventOverflow: WorldEventOverflow = WorldEventOverflow(), driveFeedback: [DriveFeedback] = []) {
        self.state = state; self.events = events
        self.eventOverflow = eventOverflow
        self.driveFeedback = driveFeedback
    }
}
