/// Tekstura zarejestrowana w rejestrze zasobów urządzenia. Identyfikator nadaje rejestr, nie gra.
public struct TextureID: Hashable, Sendable {
    public let rawValue: UInt64
    package init(rawValue: UInt64) { self.rawValue = rawValue }
}
