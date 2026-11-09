public enum PhysicsMaterialKind: Hashable, Sendable {
    case bubble
    /// Wszystkie sztywne bryły: wielokąt, koło i kapsuła.
    case rigid
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

    public init(kind: PhysicsMaterialKind, deformability: Float = 0, damping: Float = 0,
                friction: Float = 0, restitution: Float = 0,
                maximumLinearSpeed: Float? = nil, maximumAngularSpeed: Float? = nil) throws {
        try requireNonnegative(deformability, "deformability")
        try requireNonnegative(damping, "damping")
        try requireNonnegative(friction, "friction")
        try requireNonnegative(restitution, "restitution")
        guard deformability <= 1 else { throw ModelValidationError.valueOutOfRange("deformability") }
        guard restitution <= 1 else { throw ModelValidationError.valueOutOfRange("restitution") }
        if let maximumLinearSpeed { try requirePositive(maximumLinearSpeed, "maximumLinearSpeed") }
        if let maximumAngularSpeed { try requirePositive(maximumAngularSpeed, "maximumAngularSpeed") }
        self.kind = kind
        self.deformability = deformability
        self.damping = damping
        self.friction = friction
        self.restitution = restitution
        self.maximumLinearSpeed = maximumLinearSpeed
        self.maximumAngularSpeed = maximumAngularSpeed
    }
}

/// Kolor w przestrzeni liniowej o składowych w [0, 1]; zakres sprawdza `RenderMaterial`.
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
    fileprivate func validate(_ name: String) throws {
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
    public let uvOffset: SIMD2<Float>
    public let uvScale: SIMD2<Float>

    public init(texture: TextureID? = nil, color: RGBA = .white, blend: RenderBlendMode = .opaque,
                outline: RenderOutline = .none, bubbleMapping: BubbleTextureMapping = .attached,
                uvOffset: SIMD2<Float> = .zero, uvScale: SIMD2<Float> = SIMD2(1, 1)) throws {
        try color.validate("renderMaterial.color")
        try outline.color.validate("renderMaterial.outline.color")
        try requireNonnegative(outline.width, "renderMaterial.outline.width")
        try requireFinite(uvOffset.x, "renderMaterial.uvOffset"); try requireFinite(uvOffset.y, "renderMaterial.uvOffset")
        try requireFinite(uvScale.x, "renderMaterial.uvScale"); try requireFinite(uvScale.y, "renderMaterial.uvScale")
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
