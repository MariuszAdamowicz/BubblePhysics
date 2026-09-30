public struct MetalBufferCapacities: Equatable, Sendable {
    public var pairs: Int
    public var contacts: Int
    public var corrections: Int

    public init(pairs: Int = 0, contacts: Int = 0, corrections: Int = 0) {
        self.pairs = pairs
        self.contacts = contacts
        self.corrections = corrections
    }
}

public struct MetalBufferRequirements: Equatable, Sendable {
    public let pairs: Int
    public let contacts: Int
    public let corrections: Int

    public init(pairs: Int, contacts: Int, corrections: Int) {
        self.pairs = pairs
        self.contacts = contacts
        self.corrections = corrections
    }
}

public final class MetalCapacityManager {
    public private(set) var capacities: MetalBufferCapacities

    public init(capacities: MetalBufferCapacities = .init()) {
        self.capacities = capacities
    }

    @discardableResult
    public func ensureCapacity(for requirements: MetalBufferRequirements) -> Bool {
        let next = MetalBufferCapacities(
            pairs: expandedCapacity(current: capacities.pairs, required: requirements.pairs),
            contacts: expandedCapacity(current: capacities.contacts, required: requirements.contacts),
            corrections: expandedCapacity(current: capacities.corrections, required: requirements.corrections)
        )
        guard next != capacities else { return false }
        capacities = next
        return true
    }

    private func expandedCapacity(current: Int, required: Int) -> Int {
        guard current < required else { return current }
        var result = max(1, current)
        while result < required {
            result *= 2
        }
        return result
    }
}

public struct MetalStepTelemetry: Equatable, Sendable {
    public let candidatePairCount: Int
    public let contactCount: Int
    public let correctionCount: Int
    public let didOverflow: Bool
    public let didRetry: Bool

    public init(candidatePairCount: Int, contactCount: Int, correctionCount: Int, didOverflow: Bool, didRetry: Bool) {
        self.candidatePairCount = candidatePairCount
        self.contactCount = contactCount
        self.correctionCount = correctionCount
        self.didOverflow = didOverflow
        self.didRetry = didRetry
    }
}
