import BubblePhysicsModel

/// Nieuporządkowana para obiektów w kontakcie; `first` ma mniejszy `rawValue`.
package struct ContactPair: Hashable, Sendable {
    package let first: ObjectID
    package let second: ObjectID
    package init(_ a: ObjectID, _ b: ObjectID) {
        if a.rawValue <= b.rawValue { first = a; second = b } else { first = b; second = a }
    }
}

/// Domyka dyskretne zdarzenia powstające po odczycie ukończonego kroku.
/// Kontaktów merge nie przetwarza ponownie: GPU już je odfiltrowało i ograniczyło.
package enum EventCompactor {
    /// `previousContacts` to historia par z zainteresowaniem kontaktem po poprzednim kroku, a `removedObjects` to obiekty
    /// usunięte, scalone, podzielone albo zawinięte poza region w tym kroku (zadanie 21: dziś ignorowane).
    package static func finish(_ events: [WorldEvent], overflow: WorldEventOverflow,
                               feedback: [DriveFeedback], state: RuntimeState,
                               previousBlockers: [ObjectID: ObjectID],
                               previousContacts: Set<ContactPair> = [], removedObjects: Set<ObjectID> = [])
        -> (events: [WorldEvent], overflow: WorldEventOverflow, blockers: [ObjectID: ObjectID],
            contacts: Set<ContactPair>) {
        var selected = events
        var dropped = overflow.droppedCount
        var blockers: [ObjectID: ObjectID] = [:]
        for item in feedback {
            guard let blocker = item.blockingContact,
                  state.objects[item.objectID]?.interests.contains(.driveBlocked) == true else { continue }
            blockers[item.objectID] = blocker.objectID
            guard previousBlockers[item.objectID] != blocker.objectID else { continue }
            if selected.count < state.configuration.eventBufferCapacity {
                selected.append(.driveBlocked(item.objectID, by: blocker.objectID, point: blocker.point))
            } else { dropped += 1 }
        }
        return (selected, WorldEventOverflow(droppedCount: dropped), blockers, previousContacts)
    }
}
