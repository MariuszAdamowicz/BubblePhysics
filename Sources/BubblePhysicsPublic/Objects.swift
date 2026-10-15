public enum MotionRole: Hashable, Sendable {
    case `static`
    case dynamic
    case motorDriven
    case pathDriven
    case playerDriven
}

/// Polityka działa po całkowitym opuszczeniu regionu. Wrap nie tworzy kontaktów przez szew.
public enum RegionExitPolicy: Hashable, Sendable {
    case remove
    case wrap
}

/// Jeden prosty pierścień. Oba kierunki obiegu i wklęsłości są dozwolone.
public struct PolygonGeometry: Equatable, Sendable {
    /// Wierzchołki lokalne; zamykająca krawędź jest domyślna.
    public let vertices: [WorldPoint]

    /// Powtórzenie pierwszego wierzchołka na końcu jest akceptowane i normalizowane.
    /// Dziury są jawnie odrzucane; wynik nigdy nie przechowuje dodatkowych pierścieni.
    public init(vertices: [WorldPoint], holes: [[WorldPoint]] = []) throws {
        guard holes.isEmpty else { throw ModelValidationError.polygonHolesUnsupported }
        for vertex in vertices { try requireFinite(vertex, "polygon.vertex") }
        var ring = vertices
        if ring.count > 1, ring.first == ring.last { ring.removeLast() }
        guard ring.count >= 3 else { throw ModelValidationError.insufficientPolygonVertices }
        let points = ring.map { SIMD2<Double>(Double($0.x), Double($0.y)) }
        for i in points.indices {
            let a = points[i], b = points[(i + 1) % points.count], c = points[(i + 2) % points.count]
            guard a != b else { throw ModelValidationError.degeneratePolygon }
            // Współliniowe krawędzie mogą iść dalej, lecz nie mogą zawracać na siebie.
            if cross(a, b, c) == 0 {
                let ab = b - a, bc = c - b
                guard ab.x * bc.x + ab.y * bc.y >= 0 else { throw ModelValidationError.degeneratePolygon }
            }
            for j in (i + 1)..<points.count {
                if j == i + 1 || (i == 0 && j == points.count - 1) { continue }
                if intersects(a, b, points[j], points[(j + 1) % points.count]) {
                    throw ModelValidationError.selfIntersectingPolygon
                }
            }
        }
        // Double i lokalny początek zapobiegają underflow Float i utracie pola przez translację.
        let origin = points[0]
        var twiceArea: Double = 0
        for i in 1..<(points.count - 1) { twiceArea += cross(origin, points[i], points[i + 1]) }
        guard twiceArea != 0 else { throw ModelValidationError.degeneratePolygon }
        self.vertices = ring
    }
}

private func cross(_ a: SIMD2<Double>, _ b: SIMD2<Double>, _ c: SIMD2<Double>) -> Double {
    let ab = b - a, ac = c - a
    return ab.x * ac.y - ab.y * ac.x
}

private func intersects(_ a: SIMD2<Double>, _ b: SIMD2<Double>,
                        _ c: SIMD2<Double>, _ d: SIMD2<Double>) -> Bool {
    let abc = cross(a, b, c), abd = cross(a, b, d)
    let cda = cross(c, d, a), cdb = cross(c, d, b)
    func onSegment(_ p: SIMD2<Double>, _ u: SIMD2<Double>, _ v: SIMD2<Double>) -> Bool {
        p.x >= min(u.x, v.x) && p.x <= max(u.x, v.x) && p.y >= min(u.y, v.y) && p.y <= max(u.y, v.y)
    }
    if abc == 0 && onSegment(c, a, b) { return true }
    if abd == 0 && onSegment(d, a, b) { return true }
    if cda == 0 && onSegment(a, c, d) { return true }
    if cdb == 0 && onSegment(b, c, d) { return true }
    return ((abc > 0 && abd < 0) || (abc < 0 && abd > 0))
        && ((cda > 0 && cdb < 0) || (cda < 0 && cdb > 0))
}

/// Zwalidowana geometria zasięgu sensora lub pola; pozycja i obrót należą do deskryptora.
public struct RangeGeometry: Equatable, Sendable {
    public enum Shape: Equatable, Sendable {
        case circle(radius: Float)
        case polygon(PolygonGeometry)
    }

    public let shape: Shape

    public init(shape: Shape) throws {
        if case .circle(let radius) = shape { try requirePositive(radius, "range.radius") }
        self.shape = shape
    }

    public static func circle(radius: Float) throws -> Self { try Self(shape: .circle(radius: radius)) }
    public static func polygon(vertices: [WorldPoint]) throws -> Self {
        try Self(shape: .polygon(PolygonGeometry(vertices: vertices)))
    }
}

/// nil oznacza wszystkie obiekty, pusty zbiór nie wybiera żadnego obiektu.
/// Pola sił dodatkowo respektują role dynamic i motorDriven, niezależnie od filtra.
public struct ObjectFilter: Equatable, Sendable {
    public let objectIDs: Set<ObjectID>?
    public init(objectIDs: Set<ObjectID>? = nil) { self.objectIDs = objectIDs }
}

public struct BubbleDescriptor: Equatable, Sendable {
    public let id: ObjectID
    public let position: WorldPoint
    public let velocity: WorldPoint
    public let targetRadius: Float
    public let mass: Float
    public let motionRole: MotionRole
    public let regionExitPolicy: RegionExitPolicy
    public let physicsMaterialID: PhysicsMaterialID
    public let renderStyleID: RenderStyleID
    public let mergeGroups: MergeGroupSet
    public let eventInterest: EventInterest
    public let presentation: PresentationParameters

    public init(id: ObjectID, position: WorldPoint, velocity: WorldPoint = .zero,
                targetRadius: Float, mass: Float = 1, motionRole: MotionRole = .dynamic,
                regionExitPolicy: RegionExitPolicy = .remove, physicsMaterialID: PhysicsMaterialID,
                renderStyleID: RenderStyleID, mergeGroups: MergeGroupSet = [],
                eventInterest: EventInterest = [], presentation: PresentationParameters = .empty) throws {
        try requireFinite(position, "bubble.position")
        try requireFinite(velocity, "bubble.velocity")
        try requirePositive(targetRadius, "bubble.targetRadius")
        try requirePositive(mass, "bubble.mass")
        self.id = id
        self.position = position
        self.velocity = velocity
        self.targetRadius = targetRadius
        self.mass = mass
        self.motionRole = motionRole
        self.regionExitPolicy = regionExitPolicy
        self.physicsMaterialID = physicsMaterialID
        self.renderStyleID = renderStyleID
        self.mergeGroups = mergeGroups
        self.eventInterest = eventInterest
        self.presentation = presentation
    }
}

public struct PolygonDescriptor: Equatable, Sendable {
    public let id: ObjectID
    public let geometry: PolygonGeometry
    public let position: WorldPoint
    /// Obrót i prędkość kątowa w radianach i radianach na sekundę.
    public let rotation: Float
    public let velocity: WorldPoint
    public let angularVelocity: Float
    public let mass: Float
    public let momentOfInertia: Float
    public let motionRole: MotionRole
    public let regionExitPolicy: RegionExitPolicy
    public let physicsMaterialID: PhysicsMaterialID
    public let renderStyleID: RenderStyleID
    public let eventInterest: EventInterest
    public let presentation: PresentationParameters

    public init(id: ObjectID, vertices: [WorldPoint], position: WorldPoint = .zero,
                rotation: Float = 0, velocity: WorldPoint = .zero, angularVelocity: Float = 0,
                mass: Float = 1, momentOfInertia: Float = 1, motionRole: MotionRole = .static,
                regionExitPolicy: RegionExitPolicy = .remove, physicsMaterialID: PhysicsMaterialID,
                renderStyleID: RenderStyleID, eventInterest: EventInterest = [],
                presentation: PresentationParameters = .empty) throws {
        self.geometry = try PolygonGeometry(vertices: vertices)
        try requireFinite(position, "polygon.position")
        try requireFinite(rotation, "polygon.rotation")
        try requireFinite(velocity, "polygon.velocity")
        try requireFinite(angularVelocity, "polygon.angularVelocity")
        try requirePositive(mass, "polygon.mass")
        try requirePositive(momentOfInertia, "polygon.momentOfInertia")
        self.id = id
        self.position = position
        self.rotation = rotation
        self.velocity = velocity
        self.angularVelocity = angularVelocity
        self.mass = mass
        self.momentOfInertia = momentOfInertia
        self.motionRole = motionRole
        self.regionExitPolicy = regionExitPolicy
        self.physicsMaterialID = physicsMaterialID
        self.renderStyleID = renderStyleID
        self.eventInterest = eventInterest
        self.presentation = presentation
    }
}

/// Siła kierunkowa w jednostkach siły świata. Siła radialna dodatnia odpycha, ujemna przyciąga;
/// dodatnia siła wirowa działa przeciwnie do ruchu wskazówek zegara.
/// Falloff to nieujemny wykładnik zaniku względem znormalizowanej odległości w zasięgu;
/// zero oznacza stałą siłę. Ocena siły należy do runtime.
public enum ForceField: Equatable, Sendable {
    case directional(force: WorldPoint)
    case radial(strength: Float, falloff: Float)
    case vortex(strength: Float, falloff: Float)

    internal func validate() throws {
        switch self {
        case .directional(let force): try requireFinite(force, "field.force")
        case .radial(let strength, let falloff), .vortex(let strength, let falloff):
            try requireFinite(strength, "field.strength")
            try requireNonnegative(falloff, "field.falloff")
        }
    }
}

public struct ForceFieldDescriptor: Equatable, Sendable {
    public let id: ObjectID
    public let position: WorldPoint
    public let rotation: Float
    public let geometry: RangeGeometry
    public let field: ForceField
    public let filter: ObjectFilter
    public let regionExitPolicy: RegionExitPolicy
    public let renderStyleID: RenderStyleID
    public let eventInterest: EventInterest
    public let presentation: PresentationParameters

    public init(id: ObjectID, position: WorldPoint, rotation: Float = 0,
                geometry: RangeGeometry, field: ForceField, filter: ObjectFilter = ObjectFilter(),
                regionExitPolicy: RegionExitPolicy = .remove, renderStyleID: RenderStyleID,
                eventInterest: EventInterest = [], presentation: PresentationParameters = .empty) throws {
        try requireFinite(position, "field.position")
        try requireFinite(rotation, "field.rotation")
        try field.validate()
        self.id = id
        self.position = position
        self.rotation = rotation
        self.geometry = geometry
        self.field = field
        self.filter = filter
        self.regionExitPolicy = regionExitPolicy
        self.renderStyleID = renderStyleID
        self.eventInterest = eventInterest
        self.presentation = presentation
    }
}

public struct SensorDescriptor: Equatable, Sendable {
    public let id: ObjectID
    public let position: WorldPoint
    public let rotation: Float
    public let geometry: RangeGeometry
    public let filter: ObjectFilter
    public let regionExitPolicy: RegionExitPolicy
    public let renderStyleID: RenderStyleID
    public let eventInterest: EventInterest
    public let presentation: PresentationParameters

    public init(id: ObjectID, position: WorldPoint, rotation: Float = 0,
                geometry: RangeGeometry, filter: ObjectFilter = ObjectFilter(),
                regionExitPolicy: RegionExitPolicy = .remove, renderStyleID: RenderStyleID,
                eventInterest: EventInterest = [], presentation: PresentationParameters = .empty) throws {
        try requireFinite(position, "sensor.position")
        try requireFinite(rotation, "sensor.rotation")
        self.id = id
        self.position = position
        self.rotation = rotation
        self.geometry = geometry
        self.filter = filter
        self.regionExitPolicy = regionExitPolicy
        self.renderStyleID = renderStyleID
        self.eventInterest = eventInterest
        self.presentation = presentation
    }
}
