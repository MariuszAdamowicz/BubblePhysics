import Foundation

public enum WorldAdvanceIssue: Equatable, Sendable {
    case invalidTimeDelta
    case timeAccumulatorOverflow
    case stepFailed
    case advanceCancelled
    /// Równoległe advance nie dopisuje czasu; można ponowić po zakończeniu aktywnego.
    case advanceAlreadyInProgress
    /// Domknięcie gry albo kodowanie renderu rzuciło błąd: klatka odrzucona, kolejka czeka, świat żyje (etap 4).
    case frameRejected
    /// Świat jest w stanie końcowym „zawiódł”: `advance` zwraca ostatnią klatkę i nic nie robi (etap 4).
    case worldFailed
}

/// Powód stanu końcowego „zawiódł”. Jedyna droga dalej to nowy `BubbleWorld`.
public enum WorldFailureReason: Equatable, Sendable {
    /// Bufor poleceń nie zakończył się powodzeniem (błąd wykonania na GPU).
    case commandExecutionFailed
    /// Stan zawiera NaN albo ±∞.
    case nonFiniteValues
    /// Asercja kontaktu: d ≤ 0 w parze kolidującej według filtrów, środek bańki w kolidującej bryle albo zmiana strony
    /// krawędzi. To błąd silnika, a nie sceny; szczegóły w `WorldDiagnostics.failureDetail`.
    case contactViolation
    /// Klatka potrzebowała ponad 1024 podkroków. Obiekt i człon, który wyznaczył h, są w `WorldDiagnostics.failureDetail`.
    case substepLimitExceeded
}

/// Człon wzoru na h, który wyznaczył ostatni podkrok przed przekroczeniem limitu.
public enum WorldSubstepTerm: Equatable, Sendable {
    /// Pozostały czas kroku.
    case remainingTime
    /// 1 / ω_max: sztywność kontaktu, gumki i pól.
    case stiffness
    /// d / (4 · v): odległość do przeszkody w obu kierunkach.
    case distance
    /// h_zapasu: zapas obwiedni listy kandydatów.
    case margin
}

/// Szczegóły stanu „zawiódł” z przyczyną `.contactViolation` albo `.substepLimitExceeded`.
public struct WorldFailureDetail: Equatable, Sendable {
    /// Obiekty, których dotyczy awaria: para albo pojedynczy obiekt (przy limicie podkroków ten, który wyznaczał h).
    public let objects: [ObjectID]
    /// Krawędź przeszkody, gdy awaria dotyczy krawędzi; numer w wielokącie bryły.
    public let edgeIndex: Int?
    /// Odległość d w chwili awarii (ujemna albo zero przy naruszeniu kontaktu).
    public let distance: Float?
    /// Człon h z ostatniego podkroku; tylko przy `.substepLimitExceeded`.
    public let limitingTerm: WorldSubstepTerm?

    public init(objects: [ObjectID], edgeIndex: Int? = nil, distance: Float? = nil,
                limitingTerm: WorldSubstepTerm? = nil) {
        self.objects = objects; self.edgeIndex = edgeIndex; self.distance = distance; self.limitingTerm = limitingTerm
    }
}

/// Powód ostatniego odrzuconego kroku albo klatki; świat po nim żyje, a kolejka transakcji czeka.
public enum WorldRejectionReason: Equatable, Sendable {
    /// Domknięcie gry albo kodowanie renderu rzuciło błąd.
    case frameEncoding
    /// Strażnik solvera wykrył naruszenie (np. przeniknięcie).
    case solverGuard
    /// Klatka solvera z wartością skończoną, ale poza dopuszczalnym zakresem.
    case invalidFrame
    case invalidSnapshot
    case frameInFlight
    /// Inny błąd kroku (zasoby, pojemność, błąd nieznanego typu).
    case unexpected
}

/// Przyczyna odrzucenia kroku przez strażnika solvera brył (`WorldRejectionReason.solverGuard`).
public enum SolverGuardCause: Equatable, Sendable {
    /// Bryła sztywna obróciła się w jednym kroku o więcej, niż pozwala budżet 128 próbek obrotu.
    case rigidRotationBudget
}

/// Bieżąca diagnostyka harmonogramu, także gdy nie powstała nowa kompletna klatka.
public struct WorldDiagnostics: Equatable, Sendable {
    /// Cały przyjęty, jeszcze niesymulowany czas, łącznie z ułamkiem kroku.
    public let backlogSeconds: TimeInterval
    /// Kolejne ukończone wywołania advance z co najmniej jednym zaległym pełnym krokiem.
    public let consecutiveBackloggedAdvances: UInt64
    /// Suma czasu odrzuconego przez limit backlogu `WorldConfiguration.maximumBacklog` od początku świata (etap 4).
    public let discardedBacklogSeconds: TimeInterval
    public let stepsInLastAdvance: Int
    public let pendingTransactionCount: Int
    public let isPaused: Bool
    public let isAdvancing: Bool
    public let lastAdvanceIssue: WorldAdvanceIssue?
    public let eventOverflow: WorldEventOverflow
    /// Narastający licznik par kandydatów kontaktu, które nie zmieściły się w wierszu k obiektu (etap 2).
    public let contactCandidateOverflow: Int
    /// Największa liczba kandydatów kontaktu na jeden obiekt w ostatnim ukończonym kroku (etap 2).
    public let maximumContactCandidatesPerObject: Int
    /// Powód stanu końcowego „zawiódł”; nil, gdy świat działa (etap 4).
    public let failureReason: WorldFailureReason?
    /// Szczegóły stanu „zawiódł” (obiekty, krawędź, d, człon h); nil, gdy świat działa albo przyczyna ich nie niesie.
    public let failureDetail: WorldFailureDetail?
    /// Powód ostatniego odrzuconego kroku lub klatki; zostaje do następnego odrzucenia (etap 4).
    public let lastRejectionReason: WorldRejectionReason?
    /// Przyczyna ostatniego odrzucenia przez strażnika; nil, gdy nic nie odrzucono albo ostatnie odrzucenie miało inny
    /// powód niż `.solverGuard`.
    public let lastSolverGuardCause: SolverGuardCause?
    /// Prawda tylko wtedy, gdy ostatnie `advance` zatwierdziło bufor poleceń z renderem; gra prezentuje drawable tylko przy
    /// prawdzie. Pauza, stan „zawiódł”, odrzucona klatka i `advance` bez bufora dają fałsz (etap 6).
    public let didRenderLastAdvance: Bool
}
