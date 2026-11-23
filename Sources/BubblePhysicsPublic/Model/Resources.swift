import Foundation

public enum PhysicsMaterialKind: Hashable, Sendable {
    case bubble
    /// Wszystkie sztywne bryły: wielokąt, koło i kapsuła.
    case rigid
}

/// Zasób fizyczny, bez masy i promienia należących do konkretnego obiektu.
///
/// Materiał `.bubble` ma tylko sztywność kontaktu `contactStiffness` (K_c, jednostka siły: siła F = K_c · ε / (1 − ε)² ugina bańkę
/// o ułamek ε promienia) i opór ruchu `damping` (γ, 1/s). Tarcie, restytucja i limity prędkości należą do materiału `.rigid`,
/// który nie ma sztywności kontaktu bańki.
public struct PhysicsMaterial: Equatable, Sendable {
    public let kind: PhysicsMaterialKind
    /// K_c > 0 dla `.bubble`; `nil` dla `.rigid`.
    public let contactStiffness: Float?
    public let damping: Float
    public let friction: Float
    public let restitution: Float
    /// Górne granice prędkości; `nil` oznacza brak limitu. Dotyczą tylko materiału `.rigid`, także bryły kinematycznej: napęd
    /// szybszy niż limit jest przycinany do limitu. Materiał `.bubble` ma tu zawsze `nil`.
    public let maximumLinearSpeed: Float?
    public let maximumAngularSpeed: Float?

    /// `.bubble` wymaga `contactStiffness` ∈ (0, ∞) i `damping` ∈ [0, ∞), a tarcie, restytucję i limity prędkości przyjmuje tylko
    /// w wartościach domyślnych; każde złamanie to `valueOutOfRange` z nazwą pola. `.rigid` przyjmuje pola jak w v3.0.2 i nie
    /// przyjmuje `contactStiffness`.
    public init(kind: PhysicsMaterialKind, contactStiffness: Float? = nil, damping: Float = 0,
                friction: Float = 0, restitution: Float = 0,
                maximumLinearSpeed: Float? = nil, maximumAngularSpeed: Float? = nil) throws {
        switch kind {
        case .bubble:
            guard let contactStiffness, contactStiffness.isFinite, contactStiffness > 0 else {
                throw ModelValidationError.valueOutOfRange("contactStiffness")
            }
            guard damping.isFinite, damping >= 0 else { throw ModelValidationError.valueOutOfRange("damping") }
            guard friction == 0 else { throw ModelValidationError.valueOutOfRange("friction") }
            guard restitution == 0 else { throw ModelValidationError.valueOutOfRange("restitution") }
            guard maximumLinearSpeed == nil else { throw ModelValidationError.valueOutOfRange("maximumLinearSpeed") }
            guard maximumAngularSpeed == nil else { throw ModelValidationError.valueOutOfRange("maximumAngularSpeed") }
        case .rigid:
            guard contactStiffness == nil else { throw ModelValidationError.valueOutOfRange("contactStiffness") }
            try requireNonnegative(damping, "damping")
            try requireNonnegative(friction, "friction")
            try requireNonnegative(restitution, "restitution")
            guard restitution <= 1 else { throw ModelValidationError.valueOutOfRange("restitution") }
            if let maximumLinearSpeed { try requirePositive(maximumLinearSpeed, "maximumLinearSpeed") }
            if let maximumAngularSpeed { try requirePositive(maximumAngularSpeed, "maximumAngularSpeed") }
        }
        self.kind = kind
        self.contactStiffness = contactStiffness
        self.damping = damping
        self.friction = friction
        self.restitution = restitution
        self.maximumLinearSpeed = maximumLinearSpeed
        self.maximumAngularSpeed = maximumAngularSpeed
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
