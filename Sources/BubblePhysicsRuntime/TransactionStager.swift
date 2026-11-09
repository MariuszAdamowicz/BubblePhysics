import Foundation
import BubblePhysicsModel
import BubblePhysicsNativeMetal

/// Stan logiczny, całkowicie wartościowy. Nie przechowuje buforów ani uchwytów backendu.
package struct RuntimeState: Equatable, Sendable {
    package let configuration: WorldConfiguration
    package var objects: [ObjectID: RuntimeObject] = [:]
    package var physicsMaterials: [PhysicsMaterialID: PhysicsMaterial] = [:]
    package var transitions: [TransitionTarget: ParameterTransition] = [:]
    package var joints: [JointID: Joint] = [:]
    package var renderMaterials: [RenderMaterialID: RenderMaterial] = [:]
    /// Tekstura tła rozciągnięta na region symulacji; `nil` oznacza brak tła.
    package var background: TextureID?
    package var globalForce: WorldPoint
    package var nextDriveID: UInt64 = 1
    package var transitionProgress: [TransitionTarget: PhysicalTransitionProgress] = [:]

    package init(configuration: WorldConfiguration) {
        self.configuration = configuration
        self.globalForce = configuration.globalForce
    }
}

package struct RuntimeObject: Equatable, Sendable {
    package let descriptor: WorldObject
    package var motionRole: MotionRole
    package var velocity: WorldPoint
    package var position: WorldPoint
    package var previousPosition: WorldPoint
    package var rotation: Float
    package var angularVelocity: Float
    package var playerDriveTarget: WorldPoint?
    package var motionBeforeDrive: MotionRole?
    package var playerDriveID: PlayerDriveID?
    package var pathDrive: PathDrive?
    package var pathIndex = 0
    package var pathStopped = false
    package var pathBlocker: DriveBlockingContact?
    package var motorDrive: MotorDrive?
    package var kinematicDrive: KinematicDrive?
    /// Poza kinematycznej (x, y, obrót) liczona w podwójnej precyzji, żeby błąd `Float` nie narastał z krokami toru.
    package var kinematicExactPose: SIMD3<Double>?
    /// Warstwa rysowania i hit-testu: startuje z deskryptora, a `setLayer` zmienia tylko to pole (deskryptory mają pola `let`).
    package var layer: Int32 = 0
    /// Naklejka: startuje z deskryptora, a `setDecal` zmienia tylko to pole (deskryptory mają pola `let`).
    package var decal: Decal?
    package var targetRadius: Float = 0
    package var collisionRadius: Float = 0
    package var effectiveRadius: Float = 0
    /// AABB bańki z ostatniego kroku solvera; `nil`, gdy krok jeszcze jej nie policzył.
    package var bounds: WorldRectangle?
    package var capturedRadius: Float?
    package var rigidity: Float = 0
    package var structuralShape: NativeStructuralShape?
    package var radiusBlendStart: Float = 0
    package var rigidityBlendStart: Float = 0
    package var shapeElapsed: Double = 0

    init(_ descriptor: WorldObject) {
        self.descriptor = descriptor
        switch descriptor {
        case .bubble(let value): motionRole = value.motionRole; velocity = value.velocity
        case .rigidBody(let value): motionRole = value.motionRole; velocity = value.velocity
        case .forceField, .sensor: motionRole = .static; velocity = .zero
        }
        switch descriptor {
        case .bubble(let value): position = value.position; rotation = 0; angularVelocity = 0
        case .rigidBody(let value): position = value.position; rotation = value.rotation; angularVelocity = value.angularVelocity
        case .forceField(let value): position = value.position; rotation = value.rotation; angularVelocity = 0
        case .sensor(let value): position = value.position; rotation = value.rotation; angularVelocity = 0
        }
        previousPosition = position
        switch descriptor {
        case .bubble(let value): layer = value.layer; decal = value.decal
        case .rigidBody(let value): layer = value.layer; decal = value.decal
        case .forceField, .sensor: break
        }
        if case .bubble(let bubble) = descriptor {
            targetRadius = bubble.targetRadius; collisionRadius = bubble.targetRadius; effectiveRadius = bubble.targetRadius
        }
    }
    var material: (PhysicsMaterialID, PhysicsMaterialKind)? {
        switch descriptor {
        case .bubble(let value): return (value.physicsMaterialID, .bubble)
        case .rigidBody(let value): return (value.physicsMaterialID, .rigid)
        case .forceField, .sensor: return nil
        }
    }
    /// Materiał renderu obiektu; czujnik i pole sił nie są rysowane, więc go nie mają.
    package var renderMaterialID: RenderMaterialID? {
        switch descriptor {
        case .bubble(let value): return value.renderMaterialID
        case .rigidBody(let value): return value.renderMaterialID
        case .forceField, .sensor: return nil
        }
    }
    var interests: EventInterest {
        switch descriptor {
        case .bubble(let value): return value.eventInterest
        case .rigidBody(let value): return value.eventInterest
        case .forceField(let value): return value.eventInterest
        case .sensor(let value): return value.eventInterest
        }
    }
    var mass: Float? {
        switch descriptor {
        case .bubble(let value): return value.mass
        case .rigidBody(let value): return value.mass
        case .forceField, .sensor: return nil
        }
    }
}

package struct StagedWorldChange: Sendable {
    package let state: RuntimeState
    /// Zachowuje intencje, zwłaszcza merge/split. Backend realizuje je dopiero przed publikacją.
    package let operations: [WorldOperation]
    package let createdObjectIDs: [ObjectID]
    package let removedObjectIDs: [ObjectID]
    package let replacedObjectIDs: [ObjectID]
    package let events: [WorldEvent]
    /// Więzy usunięte przez transakcję, rosnąco po `JointID`.
    package let removedJointIDs: [JointID]
}

package struct PendingTransaction: Sendable {
    package let token: TransactionToken
    package let transaction: WorldTransaction
    package init(token: TransactionToken, transaction: WorldTransaction) {
        self.token = token; self.transaction = transaction
    }
}

package struct StagedTransactionBatch: Sendable {
    package let state: RuntimeState
    package let changes: [StagedWorldChange]
    /// Klatka kandydacka: warstwa świata może ją opublikować dopiero po udanym kroku backendu.
    package let frame: WorldFrame
}

extension StagedTransactionBatch {
    /// Obiekty, które pojawiły się w partii (utworzone, zastąpione, a także scalone, podzielone i wstawione przez
    /// `replaceRigidBodies`, bo te kończą się utworzeniem): ich poprzednia poza nie jest poprzednikiem nowego stanu,
    /// więc renderer nie interpoluje od niej.
    package var appearedObjectIDs: Set<ObjectID> {
        var ids = Set<ObjectID>()
        for change in changes {
            ids.formUnion(change.createdObjectIDs)
            ids.formUnion(change.replacedObjectIDs)
        }
        return ids
    }
}

package enum TransactionStager {
    /// `textureExists` mówi, czy tekstura jest w rejestrze zasobów świata; Runtime nie zna rejestru.
    package static func stage(_ transaction: WorldTransaction, against state: RuntimeState,
        textureExists: @escaping (TextureID) -> Bool = { _ in false },
        glyphLookup: @escaping GlyphLookup = { _ in nil }) throws -> StagedWorldChange {
        var candidate = StagingContext(state: state, textureExists: textureExists, glyphLookup: glyphLookup)
        for (index, operation) in transaction.operations.enumerated() {
            do { try candidate.apply(operation) }
            catch let error as TransactionRejectionReason {
                throw TransactionRejection(operationIndex: index, reason: error)
            } catch let error as ModelValidationError {
                throw TransactionRejection(operationIndex: index, reason: .invalidValue(error))
            }
        }
        return StagedWorldChange(state: candidate.state, operations: transaction.operations,
                                 createdObjectIDs: candidate.created, removedObjectIDs: candidate.removed,
                                 replacedObjectIDs: candidate.replaced, events: candidate.events,
                                 removedJointIDs: Array(Set(candidate.removedJoints)).sorted { $0.rawValue < $1.rawValue })
    }

    /// Wywoływane raz na granicy kroku. Odrzucona transakcja nie zmienia stanu dla następnej.
    /// To tylko staging: nie wykonuje kroku fizyki ani nie publikuje stanu na zewnątrz.
    package static func stageBatch(_ pending: [PendingTransaction], against state: RuntimeState,
        validate: ((StagedWorldChange) throws -> Void)? = nil,
        textureExists: @escaping (TextureID) -> Bool = { _ in false },
        glyphLookup: @escaping GlyphLookup = { _ in nil }) -> StagedTransactionBatch {
        var candidate = state
        var changes: [StagedWorldChange] = []
        var receipts: [TransactionReceipt] = []
        var events: [WorldEvent] = []
        for submission in pending {
            do {
                let change = try stage(submission.transaction, against: candidate, textureExists: textureExists,
                                       glyphLookup: glyphLookup)
                try validate?(change)
                candidate = change.state
                changes.append(change)
                receipts.append(TransactionReceipt(token: submission.token,
                    createdObjectIDs: change.createdObjectIDs, removedObjectIDs: change.removedObjectIDs,
                    replacedObjectIDs: change.replacedObjectIDs, removedJointIDs: change.removedJointIDs))
                events += change.events
            } catch let rejection as TransactionRejection {
                events.append(.transactionRejected(submission.token, rejection))
            } catch {
                // Wszystkie obecne walidatory zwracają dwa typy błędów obsługiwane przez stage.
                // Zachowujemy atomowość także przy dodaniu przyszłego walidatora.
                events.append(.transactionRejected(submission.token,
                    TransactionRejection(operationIndex: 0, reason: .invalidStructuralOperation)))
            }
        }
        return StagedTransactionBatch(state: candidate, changes: changes,
            frame: WorldFrame(transactionReceipts: receipts, events: events))
    }
}

private struct StagingContext {
    var state: RuntimeState
    let textureExists: (TextureID) -> Bool
    let glyphLookup: GlyphLookup
    var created: [ObjectID] = []
    var removed: [ObjectID] = []
    var replaced: [ObjectID] = []
    var removedJoints: [JointID] = []
    var events: [WorldEvent] = []

    mutating func apply(_ operation: WorldOperation) throws {
        switch operation {
        case .add(let descriptor): try add(descriptor)
        case .remove(let id): try remove(id)
        case .replace(let id, let descriptor):
            let previous = try object(id)
            guard descriptor.id == id else { throw TransactionRejectionReason.replacementIDMismatch(id, descriptor.id) }
            let replacement = RuntimeObject(descriptor)
            discardObjectTransitions(id)
            try validate(replacement)
            state.objects[id] = replacement
            try validateJoints(attachedTo: id)
            replaced.append(id)
            if previous.interests.contains(.didReplace) || replacement.interests.contains(.didReplace) { events.append(.didReplace(id)) }
        case .updatePhysicsMaterial(let id, let material):
            state.physicsMaterials[id] = material
            // Porządek diagnostyki nie zależy od losowego porządku Dictionary.
            for objectID in state.objects.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                if let existing = state.objects[objectID], existing.material?.0 == id { try validate(existing) }
            }
        case .updateRenderMaterial(let id, let material):
            try requireTexture(material.texture)
            state.renderMaterials[id] = material
        case .setLayer(let id, let layer):
            var existing = try object(id)
            switch existing.descriptor {
            case .bubble, .rigidBody: break
            case .forceField, .sensor: throw TransactionRejectionReason.layerNotSupported(id)
            }
            existing.layer = layer
            state.objects[id] = existing
        case .setBackground(let texture):
            try requireTexture(texture)
            state.background = texture
        case .setDecal(let id, let decal):
            var existing = try object(id)
            switch existing.descriptor {
            case .bubble, .rigidBody: break
            case .forceField, .sensor: throw TransactionRejectionReason.decalNotSupported(id)
            }
            try requireDecal(decal)
            existing.decal = decal
            state.objects[id] = existing
        case .setMotion(let id, let role):
            var existing = try physicalObject(id)
            guard role != .playerDriven || existing.playerDriveTarget != nil else {
                throw TransactionRejectionReason.driveNotActive(id)
            }
            existing.motionRole = role
            if role != .playerDriven {
                existing.playerDriveTarget = nil; existing.playerDriveID = nil; existing.motionBeforeDrive = nil
                existing.radiusBlendStart = existing.collisionRadius; existing.rigidityBlendStart = existing.rigidity; existing.shapeElapsed = 0
            }
            if role != .pathDriven { existing.pathDrive = nil; existing.pathBlocker = nil; existing.pathStopped = false }
            if role != .motorDriven { existing.motorDrive = nil }
            if role != .kinematic { existing.kinematicDrive = nil }
            try validate(existing)
            state.objects[id] = existing
            try validateJoints(attachedTo: id)
        case .setPathDrive(let id, let drive):
            try apply(.setMotion(id, .pathDriven))
            state.objects[id]?.pathDrive = drive; state.objects[id]?.pathIndex = 0
            state.objects[id]?.pathStopped = false; state.objects[id]?.pathBlocker = nil
        case .setMotorDrive(let id, let drive):
            try apply(.setMotion(id, .motorDriven))
            state.objects[id]?.motorDrive = drive
        case .setKinematicDrive(let id, let drive):
            var existing = try object(id)
            guard existing.motionRole == .kinematic else { throw TransactionRejectionReason.incompatibleMotionRole(id) }
            existing.kinematicDrive = drive
            existing.pathIndex = 0
            existing.kinematicExactPose = nil
            state.objects[id] = existing
        case .setGlobalForce(let force):
            try requireFinite(force, "globalForce")
            state.globalForce = force
        case .applyImpulse(let id, let impulse):
            try requireFinite(impulse, "impulse")
            var existing = try physicalObject(id)
            guard existing.motionRole == .dynamic || existing.motionRole == .motorDriven else {
                throw TransactionRejectionReason.incompatibleMotionRole(id)
            }
            if let mass = existing.mass {
                // Double zapobiega pośredniemu overflow, gdy wynik mieści się w Float.
                existing.velocity = WorldPoint(Float(Double(existing.velocity.x) + Double(impulse.x) / Double(mass)),
                                               Float(Double(existing.velocity.y) + Double(impulse.y) / Double(mass)))
            }
            try requireFinite(existing.velocity, "velocityAfterImpulse")
            state.objects[id] = existing
        case .beginPlayerDrive(let id, let target):
            try requireFinite(target, "playerDrive.target")
            var existing = try physicalObject(id)
            guard existing.playerDriveTarget == nil else { throw TransactionRejectionReason.driveAlreadyActive(id) }
            existing.motionBeforeDrive = existing.motionRole == .playerDriven ? .dynamic : existing.motionRole
            existing.motionRole = .playerDriven; existing.playerDriveTarget = target
            existing.playerDriveID = PlayerDriveID(rawValue: state.nextDriveID)
            guard state.nextDriveID < UInt64.max else { throw ModelValidationError.valueOutOfRange("drive.id") }
            state.nextDriveID += 1
            existing.capturedRadius = existing.effectiveRadius
            existing.radiusBlendStart = existing.collisionRadius; existing.rigidityBlendStart = existing.rigidity; existing.shapeElapsed = 0
            state.objects[id] = existing
        case .updatePlayerDrive(let id, let target):
            try requireFinite(target, "playerDrive.target")
            var existing = try physicalObject(id)
            guard existing.playerDriveTarget != nil else { throw TransactionRejectionReason.driveNotActive(id) }
            existing.playerDriveTarget = target
            state.objects[id] = existing
        case .endPlayerDrive(let id):
            var existing = try physicalObject(id)
            guard existing.playerDriveTarget != nil else { throw TransactionRejectionReason.driveNotActive(id) }
            existing.motionRole = existing.motionBeforeDrive ?? .dynamic
            existing.playerDriveTarget = nil; existing.playerDriveID = nil; existing.motionBeforeDrive = nil
            existing.radiusBlendStart = existing.collisionRadius; existing.rigidityBlendStart = existing.rigidity; existing.shapeElapsed = 0
            try validate(existing)
            state.objects[id] = existing
            try validateJoints(attachedTo: id)
        case .startTransition(let transition):
            try validate(transition)
            state.transitions[transition.target] = transition
            state.transitionProgress.removeValue(forKey: transition.target)
        case .mergeBubbles(let sources, let result): try merge(sources, result: result)
        case .splitBubble(let source, let first, let second): try split(source, first: first, second: second)
        case .replaceRigidBodies(let sources, let results):
            guard !sources.isEmpty, !results.isEmpty, Set(sources).count == sources.count else {
                throw TransactionRejectionReason.invalidStructuralOperation
            }
            for id in sources {
                guard case .rigidBody = try object(id).descriptor else { throw TransactionRejectionReason.incompatibleObjectKind(id) }
            }
            for id in sources { try remove(id) }
            for result in results { try add(.rigidBody(result)) }
        case .addJoint(let joint): try add(joint)
        case .removeJoint(let id):
            guard state.joints[id] != nil else { throw TransactionRejectionReason.jointNotFound(id) }
            state.joints.removeValue(forKey: id)
            removedJoints.append(id)
        }
    }

    func requireTexture(_ texture: TextureID?) throws {
        if let texture, !textureExists(texture) { throw TransactionRejectionReason.textureNotFound(texture) }
    }
    /// Naklejka tekstowa wymaga zarejestrowanego źródła glifów i samych znaków z jego zestawu, obrazowa zarejestrowanej tekstury.
    func requireDecal(_ decal: Decal?) throws {
        guard let decal else { return }
        switch decal.content {
        case .image(let texture, _): try requireTexture(texture)
        case .text(let string, let source):
            guard let contains = glyphLookup(source) else {
                switch source {
                case .font(let font): throw TransactionRejectionReason.fontNotFound(font)
                case .atlas(let atlas): throw TransactionRejectionReason.glyphAtlasNotFound(atlas)
                }
            }
            for character in string where !contains(character) {
                throw TransactionRejectionReason.characterNotInGlyphSet(character)
            }
        }
    }
    func object(_ id: ObjectID) throws -> RuntimeObject {
        guard let existing = state.objects[id] else { throw TransactionRejectionReason.objectNotFound(id) }
        return existing
    }
    func physicalObject(_ id: ObjectID) throws -> RuntimeObject {
        let existing = try object(id)
        guard existing.mass != nil else { throw TransactionRejectionReason.incompatibleObjectKind(id) }
        return existing
    }
    mutating func add(_ descriptor: WorldObject) throws {
        guard state.objects[descriptor.id] == nil else { throw TransactionRejectionReason.duplicateObjectID(descriptor.id) }
        let existing = RuntimeObject(descriptor)
        try validate(existing)
        state.objects[descriptor.id] = existing
        created.append(descriptor.id)
        if existing.interests.contains(.didAdd) { events.append(.didAdd(descriptor.id)) }
    }
    mutating func remove(_ id: ObjectID) throws {
        let existing = try object(id)
        state.objects.removeValue(forKey: id)
        discardObjectTransitions(id)
        removed.append(id)
        removeJoints(attachedTo: id)
        if existing.interests.contains(.didRemove) { events.append(.didRemove(id)) }
    }
    /// Usunięcie ciała (także w scaleniu, podziale i `replaceRigidBodies`) usuwa jego więzy.
    mutating func removeJoints(attachedTo id: ObjectID) {
        for (jointID, joint) in state.joints where joint.bodyA == id || joint.bodyB == id {
            state.joints.removeValue(forKey: jointID)
            removedJoints.append(jointID)
        }
    }
    mutating func add(_ joint: Joint) throws {
        guard state.joints[joint.id] == nil else { throw TransactionRejectionReason.duplicateJointID(joint.id) }
        for bodyID in [joint.bodyA] + (joint.bodyB.map { [$0] } ?? []) {
            let body = try object(bodyID)
            switch body.descriptor {
            case .bubble, .rigidBody: break
            case .forceField, .sensor: throw TransactionRejectionReason.incompatibleObjectKind(bodyID)
            }
        }
        guard jointBodiesAreSupported(joint) else { throw TransactionRejectionReason.unsupportedJointBody(joint.id) }
        state.joints[joint.id] = joint
    }
    /// Więz wymaga ciała ruchomego (dynamic, motorDriven, playerDriven), nie dopuszcza `pathDriven`,
    /// a bańka może być tylko w więzie dystansowym. Drugim końcem może być ciało nieruchome albo świat.
    func jointBodiesAreSupported(_ joint: Joint) -> Bool {
        var movable = false
        for bodyID in [joint.bodyA] + (joint.bodyB.map { [$0] } ?? []) {
            guard let body = state.objects[bodyID] else { return false }
            if case .bubble = body.descriptor, !joint.isDistance { return false }
            switch body.motionRole {
            case .pathDriven: return false
            case .dynamic, .motorDriven, .playerDriven: movable = true
            case .static, .kinematic: break
            }
        }
        return movable
    }
    /// Zmiana roli albo rodzaju ciała nie może zostawić przy nim więzu, którego stager by nie przyjął.
    func validateJoints(attachedTo id: ObjectID) throws {
        for joint in state.joints.values.sorted(by: { $0.id.rawValue < $1.id.rawValue })
        where joint.bodyA == id || joint.bodyB == id {
            guard jointBodiesAreSupported(joint) else { throw TransactionRejectionReason.unsupportedJointBody(joint.id) }
        }
    }
    mutating func discardObjectTransitions(_ id: ObjectID) {
        state.transitions = state.transitions.filter { target, _ in
            switch target {
            case .bubbleRadius(let targetID): return targetID != id
            default: return true
            }
        }
        state.transitionProgress = state.transitionProgress.filter { state.transitions[$0.key] != nil }
    }
    func validate(_ object: RuntimeObject) throws {
        if let (id, kind) = object.material {
            guard let material = state.physicsMaterials[id] else { throw TransactionRejectionReason.physicsMaterialNotFound(id) }
            guard material.kind == kind else { throw TransactionRejectionReason.incompatiblePhysicsMaterial(id, object.descriptor.id) }
        }
        if let id = object.renderMaterialID, state.renderMaterials[id] == nil {
            throw TransactionRejectionReason.renderMaterialNotFound(id)
        }
        try requireDecal(object.decal)
        switch object.descriptor {
        case .bubble(let value):
            guard object.motionRole != .kinematic else {
                throw TransactionRejectionReason.unsupportedMotionRole(value.id, .kinematic)
            }
            // Rola runtime może różnić się od roli przy dodaniu deskryptora.
            if object.motionRole == .static {
                var maximumRadius = object.targetRadius
                if let scheduled = state.transitions[.bubbleRadius(value.id)], case .scalar(let radius) = scheduled.value {
                    maximumRadius = max(maximumRadius, radius)
                }
                try state.configuration.validate(BubbleDescriptor(id: value.id, position: object.position,
                    targetRadius: maximumRadius, motionRole: .static,
                    physicsMaterialID: value.physicsMaterialID, renderMaterialID: value.renderMaterialID))
            }
        case .rigidBody(let value):
            if object.motionRole == .static {
                try state.configuration.validate(RigidBodyDescriptor(id: value.id, shape: value.shape,
                    position: object.position, rotation: object.rotation, motionRole: .static,
                    physicsMaterialID: value.physicsMaterialID, renderMaterialID: value.renderMaterialID))
            }
        case .forceField(let value): try state.configuration.validate(value)
        case .sensor(let value): try state.configuration.validate(value)
        }
    }

    func validate(_ transition: ParameterTransition) throws {
        guard transition.duration.isFinite else { throw ModelValidationError.nonFiniteValue("transition.duration") }
        guard transition.duration >= 0 else { throw ModelValidationError.valueOutOfRange("transition.duration") }
        if case .cubicBezier(let x1, let y1, let x2, let y2) = transition.curve {
            for value in [x1, y1, x2, y2] {
                try requireFinite(value, "transition.curve")
                guard (0...1).contains(value) else { throw ModelValidationError.valueOutOfRange("transition.curve") }
            }
            guard x1 <= x2 else { throw ModelValidationError.valueOutOfRange("transition.curve") }
        }
        switch (transition.target, transition.value) {
        case (.globalForce, .vector(let force)): try requireFinite(force, "transition.globalForce")
        case (.physicsMaterial(let id, let parameter), .scalar(let value)):
            guard state.physicsMaterials[id] != nil else { throw TransactionRejectionReason.physicsMaterialNotFound(id) }
            try requireNonnegative(value, "transition.material")
            if parameter == .deformability || parameter == .restitution {
                guard value <= 1 else { throw ModelValidationError.valueOutOfRange("transition.material") }
            }
        case (.bubbleRadius(let id), .scalar(let radius)):
            let existing = try object(id)
            guard case .bubble(let bubble) = existing.descriptor else { throw TransactionRejectionReason.incompatibleObjectKind(id) }
            try requirePositive(radius, "transition.radius")
            if existing.motionRole == .static {
                try state.configuration.validate(BubbleDescriptor(id: id, position: bubble.position,
                    targetRadius: radius, motionRole: .static,
                    physicsMaterialID: bubble.physicsMaterialID, renderMaterialID: bubble.renderMaterialID))
            }
        default: throw TransactionRejectionReason.incompatibleTransitionValue
        }
    }

    func bubble(_ id: ObjectID) throws -> (RuntimeObject, BubbleDescriptor) {
        let existing = try object(id)
        guard case .bubble(let value) = existing.descriptor else { throw TransactionRejectionReason.incompatibleObjectKind(id) }
        return (existing, value)
    }
    func resultDescriptor(_ result: BubbleResult, position: WorldPoint, velocity: WorldPoint,
                          radius: Float, mass: Float) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: result.id, position: position, velocity: velocity,
            targetRadius: radius, mass: mass, motionRole: result.motionRole,
            regionExitPolicy: result.regionExitPolicy, physicsMaterialID: result.physicsMaterialID,
            renderMaterialID: result.renderMaterialID, mergeGroups: result.mergeGroups,
            eventInterest: result.eventInterest, filter: result.filter, layer: result.layer, decal: result.decal))
    }
    mutating func merge(_ sources: [ObjectID], result: BubbleResult) throws {
        guard sources.count >= 2, Set(sources).count == sources.count else { throw TransactionRejectionReason.invalidStructuralOperation }
        var mass: Double = 0, radiusSquared: Double = 0
        var momentum = SIMD2<Double>.zero
        for id in sources {
            let (existing, descriptor) = try bubble(id)
            let weight = Double(descriptor.mass)
            mass += weight
            radiusSquared += Double(existing.targetRadius) * Double(existing.targetRadius)
            momentum += SIMD2<Double>(Double(existing.velocity.x), Double(existing.velocity.y)) * weight
        }
        // Wyłącznie logiczna rezerwacja wyniku. Kontur, kontakt i stan solvera obsługuje backend.
        let inputs = try sources.sorted { $0.rawValue < $1.rawValue }.map { try bubble($0).0 }
        let center = StructuralOperations.mergeCenter(inputs)
        let descriptor = try resultDescriptor(result,
            position: center,
            velocity: WorldPoint(Float(momentum.x / mass), Float(momentum.y / mass)),
            radius: Float(sqrt(radiusSquared)), mass: Float(mass))
        for id in sources { try remove(id) }
        try add(descriptor)
        if var merged = state.objects[result.id] {
            StructuralOperations.initializeMerge(&merged, sources: inputs)
            state.objects[result.id] = merged
        }
    }
    mutating func split(_ source: ObjectID, first: BubbleSplitPart, second: BubbleSplitPart) throws {
        let totalShare = Double(first.share) + Double(second.share)
        guard first.share.isFinite, second.share.isFinite, first.share > 0, second.share > 0,
              abs(totalShare - 1) <= 1e-6 else {
            throw TransactionRejectionReason.invalidStructuralOperation
        }
        let shares = (Double(first.share) / totalShare, Double(second.share) / totalShare)
        guard shares.0 > 0, shares.0 < 1, shares.1 > 0, shares.1 < 1 else {
            throw TransactionRejectionReason.invalidStructuralOperation
        }
        let (existing, descriptor) = try bubble(source)
        try remove(source)
        for (part, share) in zip([first, second], [shares.0, shares.1]) {
            try add(resultDescriptor(part.result, position: existing.position, velocity: existing.velocity,
                radius: Float(Double(existing.targetRadius) * sqrt(share)),
                mass: Float(Double(descriptor.mass) * share)))
        }
        if var a = state.objects[first.result.id], var b = state.objects[second.result.id] {
            try StructuralOperations.initializeSplit(&a, &b, source: existing, shares: shares)
            try validate(a); try validate(b)
            state.objects[first.result.id] = a; state.objects[second.result.id] = b
        }
    }
}
