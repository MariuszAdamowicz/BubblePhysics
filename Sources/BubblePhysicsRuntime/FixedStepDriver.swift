import Foundation

/// Akumulator czasu. Czas jest odejmowany dopiero po ukończeniu całego kroku.
package struct FixedStepDriver {
    package let fixedTimeStep: TimeInterval
    package let maximumStepsPerAdvance: Int
    package private(set) var backlogSeconds: TimeInterval = 0
    package private(set) var simulationTime: TimeInterval = 0
    package private(set) var completedSteps: UInt64 = 0
    package private(set) var consecutiveBackloggedAdvances: UInt64 = 0

    package init(fixedTimeStep: TimeInterval, maximumStepsPerAdvance: Int = 8) {
        precondition(fixedTimeStep.isFinite && fixedTimeStep > 0)
        precondition(maximumStepsPerAdvance > 0)
        self.fixedTimeStep = fixedTimeStep
        self.maximumStepsPerAdvance = maximumStepsPerAdvance
    }

    package var canStep: Bool {
        // Ułamek kroku pokrywa błąd wielu odejmowań. Dla kroku subnormalnego
        // tolerancja względna mogłaby obejmować wiele ULP, więc jest zerowa.
        let roundingTolerance = fixedTimeStep.isSubnormal ? 0 : fixedTimeStep * 1e-12
        return backlogSeconds >= fixedTimeStep ||
            (backlogSeconds > 0 && fixedTimeStep - backlogSeconds <= roundingTolerance)
    }

    /// Odrzucenie pozostawia cały akumulator bez zmian.
    package mutating func accumulate(_ seconds: TimeInterval) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        let accumulated = backlogSeconds + seconds
        guard accumulated.isFinite, (simulationTime + accumulated).isFinite else { return false }
        backlogSeconds = accumulated
        return true
    }

    package mutating func completeStep() {
        precondition(canStep)
        backlogSeconds = max(0, backlogSeconds - fixedTimeStep)
        simulationTime += fixedTimeStep
        completedSteps += 1
    }

    package mutating func finishAdvance() {
        consecutiveBackloggedAdvances = canStep ? consecutiveBackloggedAdvances + 1 : 0
    }
}
