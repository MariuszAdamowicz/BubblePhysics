import Foundation

public enum PhysicsMaterialKind: Hashable, Sendable {
    case bubble
    /// Wszystkie sztywne bryły: wielokąt, koło i kapsuła.
    case rigid
}

/// Podatność kontaktu bańki: c = base · r / referenceRadius, gdzie r to bieżący promień fizyczny bańki. Ta sama siła ściska więc
/// każdą bańkę o ten sam ułamek promienia, ε = c₀ · F / r_ref, a w parze wgniecenie dzieli się w proporcji podatności, czyli
/// promieni. `base` = 0 (`.hard`) to kontakt twardy z v2.1.0.
public struct BubbleContactCompliance: Equatable, Sendable {
    /// Podstawowa podatność c₀ ≥ 0; 0 oznacza kontakt twardy.
    public let base: Float
    /// Promień odniesienia r_ref > 0.
    public let referenceRadius: Float

    public init(base: Float = 0, referenceRadius: Float = 1) {
        self.base = base
        self.referenceRadius = referenceRadius
    }

    /// Kontakt twardy, jak w v2.1.0.
    public static let hard = BubbleContactCompliance()

    /// Podatność c₀ · r / r_ref w `Double` dla podanego c₀ (po nadpisaniu na bańce) i promienia r. Jedno źródło wzoru dla
    /// walidacji stagera i rekordu GPU: iloczyn w Float przepełniałby tam, gdzie walidacja w Double przepuszcza.
    /// Przy c₀ ≤ 0 zwraca 0, więc kontakt twardy nie zależy od promienia.
    package func scaledBase(_ base: Float, radius: Float) -> Double {
        guard base > 0 else { return 0 }
        return Double(base) * Double(radius) / Double(referenceRadius)
    }

    /// Każda wartość nieprawidłowa (ujemna, NaN, nieskończona, promień odniesienia ≤ 0) daje `valueOutOfRange`, a podatność > 0
    /// w materiale `.rigid` także: kontakt bańka–bryła używa tylko podatności bańki.
    internal func validate(for kind: PhysicsMaterialKind) throws {
        guard base.isFinite, base >= 0 else { throw ModelValidationError.valueOutOfRange("contactCompliance.base") }
        guard referenceRadius.isFinite, referenceRadius > 0 else {
            throw ModelValidationError.valueOutOfRange("contactCompliance.referenceRadius")
        }
        guard kind == .bubble || base == 0 else { throw ModelValidationError.valueOutOfRange("contactCompliance.base") }
    }
}

/// Zasób fizyczny, bez masy i promienia należących do konkretnego obiektu.
public struct PhysicsMaterial: Equatable, Sendable {
    public let kind: PhysicsMaterialKind
    /// 0 oznacza ciało sztywne, 1 maksymalną deformowalność materiału.
    public let deformability: Float
    public let damping: Float
    public let friction: Float
    public let restitution: Float
    /// Górne granice prędkości; `nil` oznacza brak limitu. Dotyczą każdego obiektu z tym materiałem, także kinematycznego: napęd szybszy niż limit jest przycinany do limitu.
    public let maximumLinearSpeed: Float?
    public let maximumAngularSpeed: Float?
    /// Podatność kontaktu bańki; materiał `.rigid` przyjmuje tylko `.hard`.
    public let contactCompliance: BubbleContactCompliance
    /// Współczynnik tłumienia kontaktu miękkiego ζ_c ≥ 0 jako ułamek tłumienia krytycznego sprężyny kontaktu (1 = krytyczne,
    /// 0 = bez tłumienia). Dotyczy tylko kontaktów z podatnością > 0; materiał `.rigid` przyjmuje tylko wartość domyślną 1.
    public let contactDampingRatio: Float

    public init(kind: PhysicsMaterialKind, deformability: Float = 0, damping: Float = 0,
                friction: Float = 0, restitution: Float = 0,
                maximumLinearSpeed: Float? = nil, maximumAngularSpeed: Float? = nil,
                contactCompliance: BubbleContactCompliance = .hard, contactDampingRatio: Float = 1) throws {
        try requireNonnegative(deformability, "deformability")
        try requireNonnegative(damping, "damping")
        try requireNonnegative(friction, "friction")
        try requireNonnegative(restitution, "restitution")
        guard deformability <= 1 else { throw ModelValidationError.valueOutOfRange("deformability") }
        guard restitution <= 1 else { throw ModelValidationError.valueOutOfRange("restitution") }
        if let maximumLinearSpeed { try requirePositive(maximumLinearSpeed, "maximumLinearSpeed") }
        if let maximumAngularSpeed { try requirePositive(maximumAngularSpeed, "maximumAngularSpeed") }
        try contactCompliance.validate(for: kind)
        try Self.validateContactDampingRatio(contactDampingRatio, for: kind)
        self.kind = kind
        self.deformability = deformability
        self.damping = damping
        self.friction = friction
        self.restitution = restitution
        self.maximumLinearSpeed = maximumLinearSpeed
        self.maximumAngularSpeed = maximumAngularSpeed
        self.contactCompliance = contactCompliance
        self.contactDampingRatio = contactDampingRatio
    }

    /// ζ_c skończone i ≥ 0 (NaN też daje `valueOutOfRange`). Materiał `.rigid` przyjmuje tylko 1, jak podatność kontaktu: kontakt
    /// bańka–bryła używa tylko ζ_c bańki (CD-D-15).
    private static func validateContactDampingRatio(_ ratio: Float, for kind: PhysicsMaterialKind) throws {
        guard ratio.isFinite, ratio >= 0 else { throw ModelValidationError.valueOutOfRange("contactDampingRatio") }
        guard kind == .bubble || ratio == 1 else { throw ModelValidationError.valueOutOfRange("contactDampingRatio") }
    }
}

/// Kolor o składowych w [0, 1] w przestrzeni celu renderu (potok liczy w gamma, bez konwersji liniowej); zakres sprawdza
/// `RenderMaterial`.
public struct RGBA: Equatable, Hashable, Sendable {
    public var red: Float
    public var green: Float
    public var blue: Float
    public var alpha: Float
    public init(_ red: Float, _ green: Float, _ blue: Float, _ alpha: Float = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let white = RGBA(1, 1, 1, 1)

    /// Składowe skończone i w [0, 1].
    internal func validate(_ name: String) throws {
        for component in [red, green, blue, alpha] {
            try requireFinite(component, name)
            guard (0...1).contains(component) else { throw ModelValidationError.valueOutOfRange(name) }
        }
    }
}

/// Sposób składania obiektu z tym, co pod nim.
public enum RenderBlendMode: Hashable, Sendable {
    case opaque
    case alpha
    case additive
}

/// Obrys wewnątrz konturu; szerokość 0 oznacza brak obrysu.
public struct RenderOutline: Equatable, Hashable, Sendable {
    public var color: RGBA
    /// Szerokość w jednostkach świata.
    public var width: Float
    public init(color: RGBA = .white, width: Float = 0) { self.color = color; self.width = width }
    public static let none = RenderOutline(color: .white, width: 0)
}

/// Jak tekstura leży na bańce, która się deformuje.
public enum BubbleTextureMapping: Hashable, Sendable {
    /// Punkt tekstury zostaje przy punkcie konturu.
    case attached
    /// Tekstura to koło o promieniu docelowym, które przycina kontur.
    case masked
}

/// Wygląd bańki albo bryły. Tekstura jest identyfikatorem z rejestru zasobów, a nie obrazem.
public struct RenderMaterial: Equatable, Sendable {
    public let texture: TextureID?
    public let color: RGBA
    public let blend: RenderBlendMode
    public let outline: RenderOutline
    public let bubbleMapping: BubbleTextureMapping
    /// Przesunięcie współrzędnych tekstury (z powtarzaniem). Dotyczy tylko brył; na bańkach jest ignorowane.
    public let uvOffset: SIMD2<Float>
    /// Skala współrzędnych tekstury (z powtarzaniem; niezerowa). Dotyczy tylko brył; na bańkach jest ignorowana, bo tekstura
    /// bańki leży na kole o promieniu docelowym (`bubbleMapping`).
    public let uvScale: SIMD2<Float>

    public init(texture: TextureID? = nil, color: RGBA = .white, blend: RenderBlendMode = .opaque,
                outline: RenderOutline = .none, bubbleMapping: BubbleTextureMapping = .attached,
                uvOffset: SIMD2<Float> = .zero, uvScale: SIMD2<Float> = SIMD2(1, 1)) throws {
        try color.validate("renderMaterial.color")
        try outline.color.validate("renderMaterial.outline.color")
        try requireNonnegative(outline.width, "renderMaterial.outline.width")
        try requireFinite(uvOffset, "renderMaterial.uvOffset")
        try requireFinite(uvScale, "renderMaterial.uvScale")
        guard uvScale.x != 0, uvScale.y != 0 else { throw ModelValidationError.valueOutOfRange("renderMaterial.uvScale") }
        self.texture = texture
        self.color = color
        self.blend = blend
        self.outline = outline
        self.bubbleMapping = bubbleMapping
        self.uvOffset = uvOffset
        self.uvScale = uvScale
    }
}
