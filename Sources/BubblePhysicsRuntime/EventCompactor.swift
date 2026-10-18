import BubblePhysicsModel

/// Domyka dyskretne zdarzenia powstające po odczycie ukończonego kroku.
/// Kontaktów merge nie przetwarza ponownie: GPU już je odfiltrowało i ograniczyło.
package enum EventCompactor {
    package static func finish(_ events: [WorldEvent], overflow: WorldEventOverflow,
                               feedback: [DriveFeedback], state: RuntimeState,
                               previousBlockers: [ObjectID: ObjectID])
        -> (events: [WorldEvent], overflow: WorldEventOverflow, blockers: [ObjectID: ObjectID]) {
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
        return (selected, WorldEventOverflow(droppedCount: dropped), blockers)
    }
}
