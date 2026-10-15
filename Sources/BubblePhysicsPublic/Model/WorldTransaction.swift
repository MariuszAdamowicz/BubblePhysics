import Foundation

public enum WorldObject: Equatable, Sendable {
    case bubble(BubbleDescriptor)
    case polygon(PolygonDescriptor)
    case forceField(ForceFieldDescriptor)
    case sensor(SensorDescriptor)

    public var id: ObjectID {
        switch self {
        case .bubble(let object): return object.id
        case .polygon(let object): return object.id
        case .forceField(let object): return object.id
        case .sensor(let object): return object.id
        }
    }
}

public enum PhysicsParameter: Hashable, Sendable {
    case deformability, damping, friction, restitution
}

public enum TransitionTarget: Hashable, Sendable {
    case physicsMaterial(PhysicsMaterialID, PhysicsParameter)
    case globalForce
    case renderStyle(RenderStyleID, ParameterID)
    case objectPresentation(ObjectID, ParameterID)
    case bubbleRadius(ObjectID)
}

public enum TransitionValue: Equatable, Sendable {
    case scalar(Float)
    case vector(WorldPoint)
}

public enum TransitionCurve: Equatable, Sendable, Codable {
    case linear, easeIn, easeOut, easeInOut
    /// Punkty kontrolne w przestrzeni [0, 1]; x1 <= x2 zapewnia monotoniczny czas.
    case cubicBezier(x1: Float, y1: Float, x2: Float, y2: Float)
}

/// Walidacja celu i wartości odbywa się atomowo wraz z całą transakcją.
public struct ParameterTransition: Equatable, Sendable {
    public let target: TransitionTarget
    public let value: TransitionValue
    public let duration: TimeInterval
    public let curve: TransitionCurve
    public init(target: TransitionTarget, value: TransitionValue, duration: TimeInterval,
                curve: TransitionCurve = .linear) {
        self.target = target; self.value = value; self.duration = duration; self.curve = curve
    }
}

/// Atrybuty wyniku operacji semantycznej. Pozycję, prędkość, masę i kontur wyznacza silnik.
public struct BubbleResult: Equatable, Sendable {
    public let id: ObjectID
    public let physicsMaterialID: PhysicsMaterialID
    public let renderStyleID: RenderStyleID
    public let motionRole: MotionRole
    public let regionExitPolicy: RegionExitPolicy
    public let mergeGroups: MergeGroupSet
    public let eventInterest: EventInterest
    public let presentation: PresentationParameters
    public init(id: ObjectID, physicsMaterialID: PhysicsMaterialID, renderStyleID: RenderStyleID,
                motionRole: MotionRole = .dynamic, regionExitPolicy: RegionExitPolicy = .remove,
                mergeGroups: MergeGroupSet = [], eventInterest: EventInterest = [],
                presentation: PresentationParameters = .empty) {
        self.id = id; self.physicsMaterialID = physicsMaterialID; self.renderStyleID = renderStyleID
        self.motionRole = motionRole; self.regionExitPolicy = regionExitPolicy
        self.mergeGroups = mergeGroups; self.eventInterest = eventInterest; self.presentation = presentation
    }
}

/// Udział pola powierzchni i masy źródła. Dwa dodatnie udziały muszą sumować się do 1.
public struct BubbleSplitPart: Equatable, Sendable {
    public let result: BubbleResult
    public let share: Float
    public init(result: BubbleResult, share: Float) { self.result = result; self.share = share }
}

public enum WorldOperation: Equatable, Sendable {
    case add(WorldObject)
    case remove(ObjectID)
    /// Zastąpienie zachowuje identyfikator; nowe ID wymaga remove + add.
    case replace(ObjectID, WorldObject)
    /// Tworzy zasób, jeśli identyfikator nie został wcześniej zarejestrowany.
    case updatePhysicsMaterial(PhysicsMaterialID, PhysicsMaterial)
    case updateRenderStyle(RenderStyleID, RenderStyle)
    case setMotion(ObjectID, MotionRole)
    case setGlobalForce(WorldPoint)
    case applyImpulse(ObjectID, WorldPoint)
    case beginPlayerDrive(ObjectID, WorldPoint)
    case updatePlayerDrive(ObjectID, WorldPoint)
    case endPlayerDrive(ObjectID)
    case startTransition(ParameterTransition)
    case mergeBubbles([ObjectID], BubbleResult)
    case splitBubble(ObjectID, BubbleSplitPart, BubbleSplitPart)
    case replacePolygons([ObjectID], [PolygonDescriptor])
}

/// Wartościowy builder. Każda metoda zwraca kopię; operacje zachowują kolejność dodania.
/// Zasoby należy zarejestrować przed operacją, która ich używa.
public struct WorldTransaction: Equatable, Sendable {
    public private(set) var operations: [WorldOperation]
    public init() { operations = [] }
    private func appending(_ operation: WorldOperation) -> Self {
        var result = self; result.operations.append(operation); return result
    }
    public func add(_ object: WorldObject) -> Self { appending(.add(object)) }
    public func remove(_ id: ObjectID) -> Self { appending(.remove(id)) }
    public func replace(_ id: ObjectID, with object: WorldObject) -> Self { appending(.replace(id, object)) }
    public func updatePhysicsMaterial(_ id: PhysicsMaterialID, material: PhysicsMaterial) -> Self { appending(.updatePhysicsMaterial(id, material)) }
    public func updateRenderStyle(_ id: RenderStyleID, style: RenderStyle) -> Self { appending(.updateRenderStyle(id, style)) }
    public func setMotion(_ id: ObjectID, role: MotionRole) -> Self { appending(.setMotion(id, role)) }
    public func setGlobalForce(_ force: WorldPoint) -> Self { appending(.setGlobalForce(force)) }
    public func applyImpulse(to id: ObjectID, impulse: WorldPoint) -> Self { appending(.applyImpulse(id, impulse)) }
    public func beginPlayerDrive(_ id: ObjectID, target: WorldPoint) -> Self { appending(.beginPlayerDrive(id, target)) }
    public func updatePlayerDrive(_ id: ObjectID, target: WorldPoint) -> Self { appending(.updatePlayerDrive(id, target)) }
    public func endPlayerDrive(_ id: ObjectID) -> Self { appending(.endPlayerDrive(id)) }
    public func startTransition(_ transition: ParameterTransition) -> Self { appending(.startTransition(transition)) }
    public func mergeBubbles(_ sources: [ObjectID], result: BubbleResult) -> Self { appending(.mergeBubbles(sources, result)) }
    public func splitBubble(_ source: ObjectID, first: BubbleSplitPart, second: BubbleSplitPart) -> Self { appending(.splitBubble(source, first, second)) }
    public func replacePolygons(_ sources: [ObjectID], with results: [PolygonDescriptor]) -> Self { appending(.replacePolygons(sources, results)) }
}
