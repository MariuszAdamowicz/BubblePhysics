public struct TransactionToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

/// Przyczyna, dla której środek bańki nie może stanąć w podanym punkcie. Przy kilku naraz
/// wygrywa pierwsza w kolejności: `.outsideRegion`, `.insideRigidBody`, `.coincidentCenter`.
public enum PlacementIssue: Equatable, Sendable {
    /// Środek leży poza `simulationRegion`, niezależnie od `regionExitPolicy`.
    case outsideRegion
    /// Środek leży we wnętrzu wielokąta, koła albo kapsuły bryły sztywnej.
    case insideRigidBody
    /// Środek leży bliżej środka innej bańki niż tolerancja wspólnego środka.
    case coincidentCenter
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
    case fontNotFound(FontID)
    case glyphAtlasNotFound(GlyphAtlasID)
    /// Tekst naklejki zawiera znak spoza zestawu zarejestrowanego z czcionką albo atlasem.
    case characterNotInGlyphSet(Character)
    /// `setDecal` dotyczy tylko baniek i brył; czujnik i pole sił nie są rysowane.
    case decalNotSupported(ObjectID)
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
    /// Zły punkt bańki: `add` i `replace` ze środkiem, w którym bańki nie da się poprawnie postawić, oraz
    /// `mergeBubbles` i `splitBubble`, dla których silnik nie znalazł poprawnego punktu wyniku (ID wyniku albo części).
    ///
    /// Dotyczy też bryły: `add`, `replace` i `replaceRigidBodies` bryły, której wnętrze obejmuje środek bańki kolidującej z nią
    /// według filtrów (brzeg liczy się jako wnętrze). ID to bańka, której środek leży w bryle.
    case invalidPlacement(ObjectID, PlacementIssue)
    /// Świat zawierałby po transakcji bańkę i bryłę dynamiczną (rola `.dynamic`, `.motorDriven`, `.playerDriven` albo `.pathDriven`).
    /// Nieobsługiwane w 4.0.0: bańka spotyka się tylko z bryłami statycznymi i kinematycznymi. Świat z samymi bańkami i świat
    /// z samymi bryłami dynamicznymi działają. Indeks operacji wskazuje ostatnią operację transakcji, bo reguła sprawdza stan po niej.
    case unsupportedBubbleWithDynamicRigidBody
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
        /// Minimalna odległość konturu od środka po deformacji w bieżącym kroku; nie jest promieniem docelowym. Kontur pokazuje tylko
        /// kontakty z bieżącego kroku, więc bez kontaktu wynosi tyle co promień bańki (wyjątek: w pierwszej ramce wyniku scalenia lub
        /// podziału kontur pochodzi z zalążka).
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
