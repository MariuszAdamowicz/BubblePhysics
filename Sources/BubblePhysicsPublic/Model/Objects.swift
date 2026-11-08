public enum MotionRole: Hashable, Sendable {
    case `static`
    case dynamic
    case motorDriven
    case pathDriven
    case playerDriven
    /// Nieskończona masa; ruch wyłącznie według `KinematicDrive`. Dostępna dla brył.
    case kinematic
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

/// Wspólne dla baniek i brył: filtr kolizji i zainteresowania zdarzeniami.
public struct PhysicsBodyProperties: Equatable, Hashable, Sendable {
    public let filter: CollisionFilter
    public let eventInterest: EventInterest
    public init(filter: CollisionFilter = .default, eventInterest: EventInterest = []) {
        self.filter = filter; self.eventInterest = eventInterest
    }
}

/// nil oznacza wszystkie obiekty, pusty zbiór nie wybiera żadnego obiektu.
/// Pola sił dodatkowo respektują role dynamic i motorDriven, niezależnie od filtra.
public struct ObjectFilter: Equatable, Sendable {
    public let objectIDs: Set<ObjectID>?
    public init(objectIDs: Set<ObjectID>? = nil) { self.objectIDs = objectIDs }
}

public struct BubbleDescriptor: Equatable, Sendable {
    public let drivePolicy: BubbleDrivePolicy
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
    public let filter: CollisionFilter
    public var properties: PhysicsBodyProperties { PhysicsBodyProperties(filter: filter, eventInterest: eventInterest) }
    public let presentation: PresentationParameters

    public init(id: ObjectID, position: WorldPoint, velocity: WorldPoint = .zero,
                targetRadius: Float, mass: Float = 1, motionRole: MotionRole = .dynamic,
                regionExitPolicy: RegionExitPolicy = .remove, physicsMaterialID: PhysicsMaterialID,
                renderStyleID: RenderStyleID, mergeGroups: MergeGroupSet = [],
                eventInterest: EventInterest = [], presentation: PresentationParameters = .empty,
                drivePolicy: BubbleDrivePolicy = .standard, filter: CollisionFilter = .default) throws {
        try requireFinite(position, "bubble.position")
        try requireFinite(velocity, "bubble.velocity")
        try requirePositive(targetRadius, "bubble.targetRadius")
        try requirePositive(mass, "bubble.mass")
        self.id = id
        self.drivePolicy = drivePolicy
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
        self.filter = filter
        self.presentation = presentation
    }
}

/// Kształt sztywnej bryły w jej układzie lokalnym. Środek koła i kapsuły leży w `position` bryły,
/// a oś kapsuły to lokalna oś X: odcinek od (−halfLength, 0) do (halfLength, 0) powiększony o `radius`.
public enum RigidShape: Equatable, Sendable {
    case polygon(PolygonGeometry)
    case circle(radius: Float)
    case capsule(halfLength: Float, radius: Float)

    internal func validate() throws {
        switch self {
        case .polygon: break
        case .circle(let radius): try requirePositive(radius, "shape.radius")
        case .capsule(let halfLength, let radius):
            try requirePositive(halfLength, "shape.halfLength")
            try requirePositive(radius, "shape.radius")
        }
    }

    /// Moment bezwładności jednorodnej bryły o danej masie względem jej środka ciężkości.
    /// Dla wielokąta to środek pola, a nie początek układu lokalnego.
    public func momentOfInertia(mass: Float) -> Float {
        let m = Double(mass)
        switch self {
        case .circle(let radius):
            let r = Double(radius)
            return Float(m * r * r / 2)
        case .capsule(let halfLength, let radius):
            // Prostokąt 2h × 2r i dwa półkola; półkole ma środek ciężkości 4r/(3π) od krawędzi prostej.
            let h = Double(halfLength), r = Double(radius)
            let rectangleArea = 4 * h * r, discArea = Double.pi * r * r
            let rectangleMass = m * rectangleArea / (rectangleArea + discArea)
            let discMass = m - rectangleMass
            let rectangle = rectangleMass * (4 * h * h + 4 * r * r) / 12
            let caps = discMass * (r * r / 2 + h * h + 8 * h * r / (3 * Double.pi))
            return Float(rectangle + caps)
        case .polygon(let geometry):
            // Momenty względem punktu odniesienia (pierwszy wierzchołek, dla dokładności), potem Steiner do środka pola.
            let origin = geometry.vertices[0]
            let points = geometry.vertices.map { SIMD2<Double>(Double($0.x - origin.x), Double($0.y - origin.y)) }
            var area: Double = 0, secondMoment: Double = 0
            var centroid = SIMD2<Double>.zero
            for i in points.indices {
                let a = points[i], b = points[(i + 1) % points.count]
                let cross = a.x * b.y - a.y * b.x
                area += cross
                centroid += (a + b) * cross
                secondMoment += cross * (a.x * a.x + a.x * b.x + b.x * b.x + a.y * a.y + a.y * b.y + b.y * b.y)
            }
            area /= 2
            centroid /= 6 * area
            // `secondMoment / 12` to całka r² dA względem punktu odniesienia; dzielenie przez pole daje wartość na jednostkę masy.
            let perMass = (secondMoment / 12) / area
            return Float(m * (perMass - (centroid.x * centroid.x + centroid.y * centroid.y)))
        }
    }
}

/// Sztywna bryła: wielokąt, koło albo kapsuła. Pozycja i obrót dotyczą początku układu lokalnego kształtu.
public struct RigidBodyDescriptor: Equatable, Sendable {
    public let id: ObjectID
    public let shape: RigidShape
    public let position: WorldPoint
    /// Obrót i prędkość kątowa w radianach i radianach na sekundę.
    public let rotation: Float
    public let velocity: WorldPoint
    public let angularVelocity: Float
    public let mass: Float
    /// `nil` oznacza moment liczony z kształtu i masy (`resolvedMomentOfInertia`).
    public let momentOfInertia: Float?
    public let motionRole: MotionRole
    public let regionExitPolicy: RegionExitPolicy
    public let physicsMaterialID: PhysicsMaterialID
    public let renderStyleID: RenderStyleID
    public let eventInterest: EventInterest
    public let filter: CollisionFilter
    public var properties: PhysicsBodyProperties { PhysicsBodyProperties(filter: filter, eventInterest: eventInterest) }
    public let presentation: PresentationParameters

    /// Moment bezwładności, który widzi solver: podany przez grę albo liczony z kształtu.
    public var resolvedMomentOfInertia: Float { momentOfInertia ?? shape.momentOfInertia(mass: mass) }

    public init(id: ObjectID, shape: RigidShape, position: WorldPoint = .zero,
                rotation: Float = 0, velocity: WorldPoint = .zero, angularVelocity: Float = 0,
                mass: Float = 1, momentOfInertia: Float? = nil, motionRole: MotionRole = .static,
                regionExitPolicy: RegionExitPolicy = .remove, physicsMaterialID: PhysicsMaterialID,
                renderStyleID: RenderStyleID, eventInterest: EventInterest = [],
                presentation: PresentationParameters = .empty, filter: CollisionFilter = .default) throws {
        try shape.validate()
        try requireFinite(position, "rigidBody.position")
        try requireFinite(rotation, "rigidBody.rotation")
        try requireFinite(velocity, "rigidBody.velocity")
        try requireFinite(angularVelocity, "rigidBody.angularVelocity")
        try requirePositive(mass, "rigidBody.mass")
        if let momentOfInertia { try requirePositive(momentOfInertia, "rigidBody.momentOfInertia") }
        self.id = id
        self.shape = shape
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
        self.filter = filter
        self.presentation = presentation
        // Moment liczony z kształtu może w `Float` zejść do zera przy skrajnie małej bryle.
        try requirePositive(resolvedMomentOfInertia, "rigidBody.momentOfInertia")
    }

    /// Skrót dla wielokąta o podanych wierzchołkach lokalnych.
    public init(id: ObjectID, vertices: [WorldPoint], position: WorldPoint = .zero,
                rotation: Float = 0, velocity: WorldPoint = .zero, angularVelocity: Float = 0,
                mass: Float = 1, momentOfInertia: Float? = nil, motionRole: MotionRole = .static,
                regionExitPolicy: RegionExitPolicy = .remove, physicsMaterialID: PhysicsMaterialID,
                renderStyleID: RenderStyleID, eventInterest: EventInterest = [],
                presentation: PresentationParameters = .empty, filter: CollisionFilter = .default) throws {
        try self.init(id: id, shape: .polygon(PolygonGeometry(vertices: vertices)), position: position,
                      rotation: rotation, velocity: velocity, angularVelocity: angularVelocity, mass: mass,
                      momentOfInertia: momentOfInertia, motionRole: motionRole, regionExitPolicy: regionExitPolicy,
                      physicsMaterialID: physicsMaterialID, renderStyleID: renderStyleID,
                      eventInterest: eventInterest, presentation: presentation, filter: filter)
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
