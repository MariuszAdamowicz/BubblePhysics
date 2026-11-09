import Foundation

/// Źródło zdarzeń cyklu życia aplikacji dla pauzy w tle. Świat ustawia oba uchwyty przy tworzeniu
/// i nie jest przez nie trzymany (uchwyty słabo wskazują świat).
@MainActor
public protocol LifecycleEventSource: AnyObject {
    /// Aplikacja przechodzi w tło: świat ma przestać pracować na GPU.
    var willEnterBackground: (@MainActor () -> Void)? { get set }
    /// Aplikacja wraca na pierwszy plan.
    var didBecomeActive: (@MainActor () -> Void)? { get set }
}
