import Foundation

/// Akumulator czasu. Czas jest odejmowany dopiero po ukończeniu całego kroku.
package struct FixedStepDriver {
    package let fixedTimeStep: TimeInterval
    package let maximumStepsPerAdvance: Int
    package private(set) var backlogSeconds: TimeInterval = 0
    package private(set) var simulationTime: TimeInterval = 0
    package private(set) var completedSteps: UInt64 = 0
    package private(set) var consecutiveBackloggedAdvances: UInt64 = 0
    /// Górny limit backlogu; limit krótszy niż krok działa jak jeden krok, żeby symulacja mogła ruszyć.
    package let maximumBacklog: TimeInterval
    /// Suma czasu odrzuconego przez limit backlogu od początku świata (nasyca się, nie przepełnia).
    package private(set) var discardedBacklogSeconds: TimeInterval = 0

    package init(fixedTimeStep: TimeInterval, maximumStepsPerAdvance: Int = 8,
                 maximumBacklog: TimeInterval = .infinity) {
        precondition(fixedTimeStep.isFinite && fixedTimeStep > 0)
        precondition(maximumStepsPerAdvance > 0)
        precondition(maximumBacklog > 0)
        self.fixedTimeStep = fixedTimeStep
        self.maximumStepsPerAdvance = maximumStepsPerAdvance
        self.maximumBacklog = max(maximumBacklog, fixedTimeStep)
    }

    package var canStep: Bool {
        // Ułamek kroku pokrywa błąd wielu odejmowań. Dla kroku subnormalnego
        // tolerancja względna mogłaby obejmować wiele ULP, więc jest zerowa.
        let roundingTolerance = fixedTimeStep.isSubnormal ? 0 : fixedTimeStep * 1e-12
        return backlogSeconds >= fixedTimeStep ||
            (backlogSeconds > 0 && fixedTimeStep - backlogSeconds <= roundingTolerance)
    }

    /// Odrzucenie (czas niepoprawny albo przepełnienie) pozostawia cały akumulator bez zmian.
    /// Backlog ponad limit jest obcinany, a nadmiar trafia do `discardedBacklogSeconds`.
    package mutating func accumulate(_ seconds: TimeInterval) -> Bool {
        guard seconds.isFinite, seconds >= 0 else { return false }
        let accumulated = backlogSeconds + seconds
        guard accumulated.isFinite, (simulationTime + accumulated).isFinite else { return false }
        if accumulated > maximumBacklog {
            let excess = accumulated - maximumBacklog
            let total = discardedBacklogSeconds + excess
            discardedBacklogSeconds = total.isFinite ? total : .greatestFiniteMagnitude
            backlogSeconds = maximumBacklog
        } else {
            backlogSeconds = accumulated
        }
        return true
    }

    /// Ułamek kroku zalegający w akumulatorze, obcięty do [0, 1]: waga stanu t w obrazie między t−1 i t.
    package var interpolationFraction: Double { min(max(backlogSeconds / fixedTimeStep, 0), 1) }

    /// Ułamek, który zostanie w akumulatorze po wykonaniu następnego kroku; waga nowego kroku w klatce, która ten krok niesie.
    package var interpolationFractionAfterNextStep: Double {
        min(max((backlogSeconds - fixedTimeStep) / fixedTimeStep, 0), 1)
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
