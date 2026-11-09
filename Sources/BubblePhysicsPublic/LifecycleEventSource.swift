import Foundation

/// Źródło zdarzeń cyklu życia aplikacji dla pauzy w tle. Świat ustawia oba uchwyty przy tworzeniu
/// i nie jest przez nie trzymany (uchwyty słabo wskazują świat).
///
/// Uchwyty są pojedyncze: jedno źródło obsługuje jeden świat, bo drugi świat nadpisałby uchwyty pierwszego i po cichu
/// by go odpiął. Każdy świat dostaje własne źródło (domyślnie tworzy je sam).
@MainActor
public protocol LifecycleEventSource: AnyObject {
    /// Aplikacja przechodzi w tło: świat ma przestać pracować na GPU.
    var willEnterBackground: (@MainActor () -> Void)? { get set }
    /// Aplikacja wraca na pierwszy plan.
    var didBecomeActive: (@MainActor () -> Void)? { get set }
}

/// Źródło domyślne: na iOS powiadomienia UIKit, gdzie indziej brak zdarzeń (świat nie pauzuje sam).
@MainActor
func defaultLifecycleEventSource() -> LifecycleEventSource? {
    #if canImport(UIKit) && !os(watchOS)
    return UIKitLifecycleEventSource()
    #else
    return nil
    #endif
}

#if canImport(UIKit) && !os(watchOS)
import UIKit

/// Powiadomienia UIKit: pauza zaczyna się przy `didEnterBackground` (wejście w tło), a nie przy `willResignActive`, który
/// wywołują też centrum sterowania, baner połączenia i alert systemowy; `didBecomeActive` kończy pauzę.
@MainActor
final class UIKitLifecycleEventSource: LifecycleEventSource {
    var willEnterBackground: (@MainActor () -> Void)?
    var didBecomeActive: (@MainActor () -> Void)?
    private let observers = Observers()

    /// Odpina obserwatorów poza MainActor, bo `deinit` nie ma izolacji.
    private final class Observers: @unchecked Sendable {
        var tokens: [NSObjectProtocol] = []
        deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }

    init() {
        let center = NotificationCenter.default
        observers.tokens = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.willEnterBackground?() }
            },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.didBecomeActive?() }
            }
        ]
    }
}
#endif
