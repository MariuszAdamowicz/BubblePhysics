import BubblePhysicsModel

/// Domyka dyskretne zdarzenia powstające po odczycie ukończonego kroku.
/// Zdarzenia kontaktu GPU i `NativePublicWorld` przychodzą w kolejności, którą ustalił skan, a `mergeContact` w kolejności
/// atomików, więc kompaktor układa je po parze: w parze `contactBegan` przed `mergeContact`, potem `contactEnded`.
package enum EventCompactor {
    /// `previousContacts` to historia par z dostarczonym początkiem po poprzednim kroku, a `removedObjects` to obiekty
    /// usunięte, scalone, podzielone albo zawinięte poza region w tym kroku: ich pary dostają koniec kontaktu.
    /// Koniec bez dostarczonego początku jest pomijany, a początek pary, która już jest w historii (jej koniec przepadł
    /// w przepełnieniu), też. Koniec, który nie mieści się w buforze, zostaje w historii do następnego kroku.
    package static func finish(_ events: [WorldEvent], overflow: WorldEventOverflow,
                               feedback: [DriveFeedback], state: RuntimeState,
                               previousBlockers: [ObjectID: ObjectID],
                               previousContacts: Set<ContactPair> = [], removedObjects: Set<ObjectID> = [])
        -> (events: [WorldEvent], overflow: WorldEventOverflow, blockers: [ObjectID: ObjectID],
            contacts: Set<ContactPair>) {
        let capacity = state.configuration.eventBufferCapacity
        var dropped = overflow.droppedCount
        var history = previousContacts
        var selected = orderedContactEvents(events, history: &history)
        for pair in history.sorted() where removedObjects.contains(pair.first) || removedObjects.contains(pair.second) {
            if removedObjects.contains(pair.first) && removedObjects.contains(pair.second) { history.remove(pair); continue }
            if selected.count < capacity {
                selected.append(.contactEnded(pair.first, pair.second)); history.remove(pair)
            } else { dropped += 1 }
        }
        var blockers: [ObjectID: ObjectID] = [:]
        for item in feedback {
            guard let blocker = item.blockingContact,
                  state.objects[item.objectID]?.interests.contains(.driveBlocked) == true else { continue }
            blockers[item.objectID] = blocker.objectID
            guard previousBlockers[item.objectID] != blocker.objectID else { continue }
            if selected.count < capacity {
                selected.append(.driveBlocked(item.objectID, by: blocker.objectID, point: blocker.point))
            } else { dropped += 1 }
        }
        return (selected, WorldEventOverflow(droppedCount: dropped), blockers, history)
    }

    /// Zdarzenia pary układają się w slotach, które zajmowały, po (para, rodzaj); reszta zdarzeń zostaje na miejscu.
    private static func orderedContactEvents(_ events: [WorldEvent], history: inout Set<ContactPair>) -> [WorldEvent] {
        func rank(_ event: WorldEvent) -> (pair: ContactPair, kind: Int)? {
            switch event {
            case .contactBegan(let a, let b, _, _, _): return (ContactPair(a, b), 0)
            case .mergeContact(let a, let b, _): return (ContactPair(a, b), 1)
            case .contactEnded(let a, let b): return (ContactPair(a, b), 2)
            default: return nil
            }
        }
        let slots = events.indices.filter { rank(events[$0]) != nil }
        let sorted = slots.map { events[$0] }.sorted { x, y in
            let l = rank(x)!, r = rank(y)!
            return l.pair == r.pair ? l.kind < r.kind : l.pair < r.pair
        }
        var kept: [WorldEvent] = []
        for event in sorted {
            let (pair, kind) = rank(event)!
            switch kind {
            case 0: guard history.insert(pair).inserted else { continue }
            case 2: guard history.remove(pair) != nil else { continue }
            default: break
            }
            kept.append(event)
        }
        // Pomijane zdarzenia zwalniają sloty (kept ma nie więcej elementów niż slotów).
        var next = kept.makeIterator()
        return events.compactMap { rank($0) == nil ? $0 : next.next() }
    }
}
