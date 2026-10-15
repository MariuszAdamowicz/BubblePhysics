import BubblePhysicsModel
import Metal

/// Granica atomowej publikacji. Implementacja zwraca dopiero kompletny stan i zdarzenia.
/// Przy błędzie nie wolno zmienić wcześniej opublikowanego stanu ani jego zasobów.
@MainActor
package protocol CompleteStepper: AnyObject {
    func completeStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep
}

package struct CompletedRuntimeStep {
    package let state: RuntimeState
    package let events: [WorldEvent]
    package init(state: RuntimeState, events: [WorldEvent] = []) {
        self.state = state; self.events = events
    }
}

/// Tymczasowy szew Task 4: zatwierdza stan logiczny, ale NIE wykonuje fizyki.
/// Task 5 zastąpi go adapterem GPU-native; nie jest to backend ani fallback CPU.
@MainActor
package final class NoOpCompleteStepper: CompleteStepper {
    private let device: MTLDevice?
    package init(device: MTLDevice?) { self.device = device }
    package func completeStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep {
        CompletedRuntimeStep(state: batch.state)
    }
}
