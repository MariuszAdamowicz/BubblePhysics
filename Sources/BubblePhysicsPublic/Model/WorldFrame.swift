public struct TransactionToken: RawRepresentable, Hashable, Sendable {
    public let rawValue: UInt64
    public init(rawValue: UInt64) { self.rawValue = rawValue }
}

public enum TransactionRejectionReason: Error, Equatable, Sendable {
    case objectNotFound(ObjectID)
    case duplicateObjectID(ObjectID)
    case replacementIDMismatch(ObjectID, ObjectID)
    case physicsMaterialNotFound(PhysicsMaterialID)
    case renderStyleNotFound(RenderStyleID)
    case incompatiblePhysicsMaterial(PhysicsMaterialID, ObjectID)
    case incompatibleObjectKind(ObjectID)
    case incompatibleMotionRole(ObjectID)
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
    package init(token: TransactionToken, createdObjectIDs: [ObjectID], removedObjectIDs: [ObjectID], replacedObjectIDs: [ObjectID]) {
        self.token = token; self.createdObjectIDs = createdObjectIDs
        self.removedObjectIDs = removedObjectIDs; self.replacedObjectIDs = replacedObjectIDs
    }
}

public enum WorldEvent: Equatable, Sendable {
    case transactionRejected(TransactionToken, TransactionRejection)
    case didAdd(ObjectID)
    case didRemove(ObjectID)
    case didReplace(ObjectID)
}

/// Niezmienny wynik publikacji. Runtime dodaje kolejne dane klatki w następnych etapach.
public struct WorldFrame: Equatable, Sendable {
    public let transactionReceipts: [TransactionReceipt]
    public let events: [WorldEvent]
    package init(transactionReceipts: [TransactionReceipt], events: [WorldEvent]) {
        self.transactionReceipts = transactionReceipts; self.events = events
    }
}
