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
    /// Górne granice prędkości; `nil` oznacza brak limitu. Dotyczą każdego obiektu z tym materiałem.
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

/// Identyfikacja shaderu bez zależności od API platformy graficznej.
public enum RenderShader: Hashable, Sendable {
    case technical
    /// Klucz rozwiązywany przez renderer gry.
    case custom(String)
}

public struct PresentationParameters: Equatable, Sendable {
    public let channels: [ParameterID: Float]
    public static let empty = PresentationParameters()

    private init() { channels = [:] }

    public init(channels: [ParameterID: Float]) throws {
        for (id, value) in channels { try requireFinite(value, id.rawValue) }
        self.channels = channels
    }
}

public struct RenderStyle: Equatable, Sendable {
    public let shader: RenderShader
    public let presentation: PresentationParameters

    public init(shader: RenderShader = .technical, channels: [ParameterID: Float] = [:]) throws {
        self.shader = shader
        self.presentation = try PresentationParameters(channels: channels)
    }

    /// Wartość lokalna zastępuje kanał stylu o tym samym identyfikatorze.
    public func resolvedChannels(overrides local: PresentationParameters) -> [ParameterID: Float] {
        presentation.channels.merging(local.channels) { _, local in local }
    }
}
