/// Współrzędne świata: oś X w prawo, oś Y w górę.
public typealias WorldPoint = SIMD2<Float>

/// Identyfikatory nadaje gra; różne rodzaje zasobów mają odrębne przestrzenie nazw.
public struct ObjectID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct PhysicsMaterialID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct RenderStyleID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public struct ParameterID: RawRepresentable, Hashable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// Dokładnie 64 grupy zarządzane przez grę. Pusta maska nie pasuje do żadnej grupy.
public struct MergeGroupSet: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public func overlaps(_ other: Self) -> Bool { rawValue & other.rawValue != 0 }
}

/// Żądania zdarzeń obiektu; samo ustawienie maski nie uruchamia żadnej symulacji.
public struct EventInterest: OptionSet, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
    public static let mergeContact = Self(rawValue: 1 << 0)
    public static let driveBlocked = Self(rawValue: 1 << 1)
    public static let enteredSensor = Self(rawValue: 1 << 2)
    public static let exitedSensor = Self(rawValue: 1 << 3)
    public static let didExitSimulationRegion = Self(rawValue: 1 << 4)
    public static let didWrap = Self(rawValue: 1 << 5)
    public static let didAdd = Self(rawValue: 1 << 6)
    public static let didRemove = Self(rawValue: 1 << 7)
    public static let didReplace = Self(rawValue: 1 << 8)
}
