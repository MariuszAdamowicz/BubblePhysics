public struct ReferenceContactEvent: Sendable, Equatable, Comparable {
    public var time: Float
    public var contactID: ReferenceContactID

    public init(time: Float, contactID: ReferenceContactID) {
        self.time = time
        self.contactID = contactID
    }

    public static func < (lhs: ReferenceContactEvent, rhs: ReferenceContactEvent) -> Bool {
        if lhs.time != rhs.time { return lhs.time < rhs.time }
        return lhs.contactID < rhs.contactID
    }
}

public struct ReferenceContactEventGroup: Sendable, Equatable {
    public var time: Float
    public var events: [ReferenceContactEvent]

    public init(time: Float, events: [ReferenceContactEvent]) {
        self.time = time
        self.events = events
    }
}

public enum ReferenceContactEventQueue {
    public static func groups(
        events: [ReferenceContactEvent],
        frameDuration: Float,
        simultaneousTolerance: Float,
        limit: Int
    ) -> (groups: [ReferenceContactEventGroup], didReachLimit: Bool) {
        guard frameDuration.isFinite, frameDuration >= 0 else { return ([], false) }
        let tolerance = simultaneousTolerance.isFinite ? max(0, simultaneousTolerance) : 0
        let validEvents = events
            .filter { $0.time.isFinite && $0.time >= 0 && $0.time <= frameDuration }
            .sorted()

        var allGroups: [ReferenceContactEventGroup] = []
        for event in validEvents {
            if let lastIndex = allGroups.indices.last,
               event.time - allGroups[lastIndex].time <= tolerance {
                allGroups[lastIndex].events.append(event)
                allGroups[lastIndex].events.sort { $0.contactID < $1.contactID }
            } else {
                allGroups.append(.init(time: event.time, events: [event]))
            }
        }

        let safeLimit = max(0, limit)
        let didReachLimit = allGroups.count > safeLimit
        return (Array(allGroups.prefix(safeLimit)), didReachLimit)
    }
}
