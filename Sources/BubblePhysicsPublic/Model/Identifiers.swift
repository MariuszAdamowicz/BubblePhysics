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

public struct RenderMaterialID: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
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
    public static let contact = Self(rawValue: 1 << 9)
}

/// Filtr kolizji: dwa obiekty kolidują tylko wtedy, gdy kategoria każdego z nich jest w masce drugiego.
public struct CollisionFilter: Equatable, Hashable, Sendable {
    public let category: UInt32
    public let mask: UInt32
    public init(category: UInt32 = 1, mask: UInt32 = .max) { self.category = category; self.mask = mask }
    /// Domyślny filtr: kolizja ze wszystkim.
    public static let `default` = CollisionFilter()
    public func collides(with other: CollisionFilter) -> Bool {
        category & other.mask != 0 && other.category & mask != 0
    }
}

/// Nieuporządkowana para obiektów w kontakcie; `first` ma mniejszy `rawValue`.
package struct ContactPair: Hashable, Comparable, Sendable {
    package let first: ObjectID
    package let second: ObjectID
    package init(_ a: ObjectID, _ b: ObjectID) {
        if a.rawValue <= b.rawValue { first = a; second = b } else { first = b; second = a }
    }
    package static func < (l: Self, r: Self) -> Bool {
        (l.first.rawValue, l.second.rawValue) < (r.first.rawValue, r.second.rawValue)
    }
}
