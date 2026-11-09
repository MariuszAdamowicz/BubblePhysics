public struct TransactionToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public enum TransactionRejectionReason: Error, Equatable, Sendable {
    case objectNotFound(ObjectID)
    case duplicateObjectID(ObjectID)
    case replacementIDMismatch(ObjectID, ObjectID)
    case physicsMaterialNotFound(PhysicsMaterialID)
    case renderMaterialNotFound(RenderMaterialID)
    case textureNotFound(TextureID)
    /// `setLayer` dotyczy tylko baniek i brył; czujnik i pole sił nie są rysowane.
    case layerNotSupported(ObjectID)
    case incompatiblePhysicsMaterial(PhysicsMaterialID, ObjectID)
    case incompatibleObjectKind(ObjectID)
    case jointNotFound(JointID)
    case duplicateJointID(JointID)
    /// Więz wymaga ciała, którego rola albo rodzaj go nie dopuszcza: zawias lub spaw z bańką, ciało `pathDriven`
    /// albo więz bez żadnego ciała ruchomego (dynamic, motorDriven, playerDriven).
    case unsupportedJointBody(JointID)
    case incompatibleMotionRole(ObjectID)
    /// Tymczasowy limit wdrożonego runtime; deskryptor nadal jest poprawny dla kontraktu v1.
    case unsupportedMotionRole(ObjectID, MotionRole)
    case unsupportedPhysicsParameter(PhysicsMaterialID, PhysicsParameter)
    case driveAlreadyActive(ObjectID)
    case driveNotActive(ObjectID)
    case invalidValue(ModelValidationError)
    case incompatibleTransitionValue
    case invalidStructuralOperation
}

public struct TransactionRejection: Error, Equatable, Sendable {
    public let operationIndex: Int
    public let reason: TransactionRejectionReason
    public init(operationIndex: Int, reason: TransactionRejectionReason) {
        self.operationIndex = operationIndex; self.reason = reason
    }
}

/// Wynik zaakceptowanej transakcji; identyfikatory odnoszą się do operacji, nie indeksów GPU.
public struct TransactionReceipt: Equatable, Sendable {
    public let token: TransactionToken
    public let createdObjectIDs: [ObjectID]
    public let removedObjectIDs: [ObjectID]
    public let replacedObjectIDs: [ObjectID]
    /// Więzy usunięte przez transakcję (rosnąco po `JointID`): jawnym `removeJoint` albo razem z ciałem, które łączyły.
    public let removedJointIDs: [JointID]
    package init(token: TransactionToken, createdObjectIDs: [ObjectID], removedObjectIDs: [ObjectID], replacedObjectIDs: [ObjectID],
                 removedJointIDs: [JointID] = []) {
        self.token = token; self.createdObjectIDs = createdObjectIDs
        self.removedObjectIDs = removedObjectIDs; self.replacedObjectIDs = replacedObjectIDs
        self.removedJointIDs = removedJointIDs
    }
}

public enum WorldEvent: Equatable, Sendable {
    case transactionRejected(TransactionToken, TransactionRejection)
    case didAdd(ObjectID)
    case didRemove(ObjectID)
    case didReplace(ObjectID)
    case mergeContact(ObjectID, ObjectID, point: WorldPoint)
    case driveBlocked(ObjectID, by: ObjectID, point: WorldPoint)
    case enteredSensor(sensor: ObjectID, object: ObjectID)
    case exitedSensor(sensor: ObjectID, object: ObjectID)
    case didExitSimulationRegion(ObjectID)
    case didWrap(ObjectID)
    /// Początek kontaktu pary; normalna od pierwszego obiektu do drugiego.
    case contactBegan(ObjectID, ObjectID, point: WorldPoint, normal: WorldPoint, impulse: Float)
    case contactEnded(ObjectID, ObjectID)
}

/// Stan jednej bańki albo bryły po ostatnim ukończonym kroku. Czujniki i pola sił nie mają stanu.
public struct ObjectState: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// Efektywny promień po deformacji i odbudowie; nie jest promieniem docelowym.
        case bubble(effectiveRadius: Float)
        case polygon
        case circle(radius: Float)
        case capsule(halfLength: Float, radius: Float)
    }

    public let kind: Kind
    public let position: WorldPoint
    public let velocity: WorldPoint
    public let rotation: Float
    public let angularVelocity: Float
    /// Osiowy prostokąt otaczający; dla bańki obejmuje cały zdeformowany kontur.
    public let bounds: WorldRectangle

    package init(kind: Kind, position: WorldPoint, velocity: WorldPoint, rotation: Float,
                 angularVelocity: Float, bounds: WorldRectangle) {
        self.kind = kind; self.position = position; self.velocity = velocity
        self.rotation = rotation; self.angularVelocity = angularVelocity; self.bounds = bounds
    }
}

/// Ostatni kompletny stan. Wyniki transakcji i zdarzenia obejmują wszystkie kroki
/// ukończone w wywołaniu advance, które opublikowało tę klatkę.
/// Brak nowego kroku zwraca tę samą klatkę; stepIndex pozwala uniknąć powtórnej obsługi zdarzeń.
public struct WorldFrame: Equatable, Sendable {
    public let stepIndex: UInt64
    public let simulationTime: Double
    public let transactionReceipts: [TransactionReceipt]
    public let events: [WorldEvent]
    public let eventOverflow: WorldEventOverflow
    public let driveFeedback: [DriveFeedback]
    /// Stan każdej istniejącej bańki i bryły po ostatnim kroku.
    public let objects: [ObjectID: ObjectState]
    package init(stepIndex: UInt64 = 0, simulationTime: Double = 0,
                 transactionReceipts: [TransactionReceipt], events: [WorldEvent],
                 eventOverflow: WorldEventOverflow = WorldEventOverflow(), driveFeedback: [DriveFeedback] = [],
                 objects: [ObjectID: ObjectState] = [:]) {
        self.stepIndex = stepIndex; self.simulationTime = simulationTime
        self.transactionReceipts = transactionReceipts; self.events = events
        self.eventOverflow = eventOverflow
        self.driveFeedback = driveFeedback
        self.objects = objects
    }
}
