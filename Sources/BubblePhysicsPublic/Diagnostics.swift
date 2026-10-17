import Foundation

public enum WorldAdvanceIssue: Equatable, Sendable {
    case invalidTimeDelta
    case timeAccumulatorOverflow
    case stepFailed
    case advanceCancelled
    /// Równoległe advance nie dopisuje czasu; można ponowić po zakończeniu aktywnego.
    case advanceAlreadyInProgress
}

/// Bieżąca diagnostyka harmonogramu, także gdy nie powstała nowa kompletna klatka.
public struct WorldDiagnostics: Equatable, Sendable {
    /// Cały przyjęty, jeszcze niesymulowany czas, łącznie z ułamkiem kroku.
    public let backlogSeconds: TimeInterval
    /// Kolejne ukończone wywołania advance z co najmniej jednym zaległym pełnym krokiem.
    public let consecutiveBackloggedAdvances: UInt64
    public let stepsInLastAdvance: Int
    public let pendingTransactionCount: Int
    public let isPaused: Bool
    public let isAdvancing: Bool
    public let lastAdvanceIssue: WorldAdvanceIssue?
    public let eventOverflow: WorldEventOverflow
}
