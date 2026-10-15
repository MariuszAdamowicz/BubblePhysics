import BubblePhysicsRuntime

/// Publiczna fasada świata; cykl symulacji zostanie dodany w kolejnych etapach API v1.
@MainActor
public final class BubbleWorld {
    internal init() {}
}

/// Niezmienna transakcja świata; gramatyka operacji należy do kolejnego etapu API v1.
public struct WorldTransaction {}

/// Opublikowana klatka świata; jej zawartość należy do kolejnego etapu API v1.
public struct WorldFrame {}
