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
    package init(state: RuntimeState, events: [WorldEvent] = []) {
        self.state = state; self.events = events
    }
}
