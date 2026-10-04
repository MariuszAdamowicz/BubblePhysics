public struct ReferenceContactSet: Sendable, Equatable {
    public private(set) var contacts: [ReferenceContact]

    public init(contacts: [ReferenceContact] = []) {
        self.contacts = contacts.sorted { $0.id < $1.id }
    }

    public mutating func update(
        candidates: [ReferenceContact],
        bubbles: [ReferenceBubble],
        segments: [ReferenceSegment],
        configuration: ReferenceConfiguration
    ) {
        let existing = Dictionary(uniqueKeysWithValues: contacts.map { ($0.id, $0) })
        var updatedByID: [ReferenceContactID: ReferenceContact] = [:]

        for var candidate in candidates.sorted(by: { $0.id < $1.id }) {
            if let previous = existing[candidate.id] {
                guard candidate.penetration >= -configuration.separationTolerance else { continue }
                candidate.age = previous.age + 1
                candidate.accumulatedCompression = previous.accumulatedCompression
                candidate.compressionA = previous.compressionA
                candidate.compressionB = previous.compressionB
                candidate.pressure = previous.pressure
                candidate.effectiveStiffness = previous.effectiveStiffness
                updatedByID[candidate.id] = candidate
            } else if candidate.penetration > configuration.contactTolerance {
                candidate.age = 0
                updatedByID[candidate.id] = candidate
            }
        }

        contacts = updatedByID.values.sorted { $0.id < $1.id }
    }

    mutating func replaceContacts(_ updated: [ReferenceContact]) {
        contacts = updated.sorted { $0.id < $1.id }
    }
}
