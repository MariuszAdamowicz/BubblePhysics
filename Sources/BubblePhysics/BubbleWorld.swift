public struct WorldDiagnostics: Equatable, Sendable {
    public let bubbleCount: Int
    public let appliedCommandCount: Int
    public let candidatePairCount: Int
    public let contactPairCount: Int

    public init(bubbleCount: Int, appliedCommandCount: Int, candidatePairCount: Int = 0, contactPairCount: Int = 0) {
        self.bubbleCount = bubbleCount
        self.appliedCommandCount = appliedCommandCount
        self.candidatePairCount = candidatePairCount
        self.contactPairCount = contactPairCount
    }
}

public struct WorldStepReport: Equatable, Sendable {
    public let fixedTimeStep: Float
    public let appliedCommandCount: Int
    public let diagnostics: WorldDiagnostics

    public init(fixedTimeStep: Float, appliedCommandCount: Int, diagnostics: WorldDiagnostics) {
        self.fixedTimeStep = fixedTimeStep
        self.appliedCommandCount = appliedCommandCount
        self.diagnostics = diagnostics
    }
}

private struct BubbleState: Sendable {
    let restArea: Float
    let centerIndex: Int
    let boundaryIndices: [Int]
    var distanceConstraints: [DistanceConstraint]
    var areaConstraint: AreaConstraint
}

public struct BubbleWorld: Sendable {
    public let configuration: WorldConfiguration
    public let bounds: AABB?
    public private(set) var gravity: Vector2

    private var queuedCommands: [WorldCommand] = []
    private var nextBubbleIdentifier = 1
    private var particles = ParticleStore()
    private var states: [BubbleID: BubbleState] = [:]
    private var bubbleOrder: [BubbleID] = []
    private var broadPhase = BroadPhase()
    private var contactGraph = ContactGraph()
    private var polygons: [PolygonID: RigidPolygon] = [:]
    private var polygonOrder: [PolygonID] = []

    public init(configuration: WorldConfiguration, bounds: AABB? = nil) {
        self.configuration = configuration
        self.bounds = bounds
        gravity = .zero
    }

    public mutating func reserveBubbleID() -> BubbleID {
        defer { nextBubbleIdentifier += 1 }
        return BubbleID(rawValue: nextBubbleIdentifier)
    }

    @discardableResult
    public mutating func addBubble(center: Vector2, restArea: Float) -> BubbleID {
        let id = reserveBubbleID()
        let topology = BubbleTopology.regular(
            id: id,
            center: center,
            restArea: restArea,
            maxBoundarySegmentLength: configuration.maxBoundarySegmentLength
        )
        let centerIndex = particles.append(Particle(position: center))
        let boundaryIndices = topology.boundaryPoints.map { particles.append(Particle(position: $0)) }
        var constraints: [DistanceConstraint] = []
        for offset in boundaryIndices.indices {
            let current = boundaryIndices[offset]
            let next = boundaryIndices[(offset + 1) % boundaryIndices.count]
            let diagonal = boundaryIndices[(offset + 2) % boundaryIndices.count]
            constraints.append(DistanceConstraint(first: centerIndex, second: current, restLength: length(particles[current].position - center)))
            constraints.append(DistanceConstraint(first: current, second: next, restLength: length(particles[next].position - particles[current].position)))
            constraints.append(DistanceConstraint(first: current, second: diagonal, restLength: length(particles[diagonal].position - particles[current].position)))
        }
        states[id] = BubbleState(
            restArea: restArea,
            centerIndex: centerIndex,
            boundaryIndices: boundaryIndices,
            distanceConstraints: constraints,
            areaConstraint: AreaConstraint(indices: boundaryIndices, restArea: restArea)
        )
        bubbleOrder.append(id)
        synchronizeBroadPhase()
        return id
    }

    public func bubble(_ id: BubbleID) -> BubbleTopology? {
        guard let state = states[id] else { return nil }
        return BubbleTopology(
            id: id,
            center: particles[state.centerIndex].position,
            restArea: state.restArea,
            boundaryPoints: state.boundaryIndices.map { particles[$0].position }
        )
    }

    public func currentArea(of id: BubbleID) -> Float? {
        guard let topology = bubble(id), topology.boundaryPoints.count >= 3 else { return nil }
        var doubleArea: Float = 0
        for offset in topology.boundaryPoints.indices {
            let current = topology.boundaryPoints[offset]
            let next = topology.boundaryPoints[(offset + 1) % topology.boundaryPoints.count]
            doubleArea += current.x * next.y - current.y * next.x
        }
        return abs(doubleArea) * 0.5
    }

    public mutating func enqueue(_ command: WorldCommand) {
        queuedCommands.append(command)
    }

    public mutating func addRigidPolygon(_ polygon: RigidPolygon) {
        precondition(polygons[polygon.id] == nil)
        polygons[polygon.id] = polygon
        polygonOrder.append(polygon.id)
    }

    @discardableResult
    public mutating func step() -> WorldStepReport {
        let commands = queuedCommands
        queuedCommands.removeAll(keepingCapacity: true)
        var forces = Dictionary(uniqueKeysWithValues: bubbleOrder.map { ($0, Vector2.zero) })

        for command in commands {
            switch command {
            case let .setGravity(value):
                gravity = value
            case let .applyForce(id, force):
                forces[id] = (forces[id] ?? .zero) + force
            case let .setKinematicTransform(id, position, angleRadians, linearVelocity, angularVelocity):
                guard var polygon = polygons[id] else { continue }
                polygon.setKinematicTransform(position: position, angleRadians: angleRadians, linearVelocity: linearVelocity, angularVelocity: angularVelocity)
                polygons[id] = polygon
            }
        }

        predictPositions(forces: forces)
        solveConstraints()
        synchronizeBroadPhase()

        let diagnostics = WorldDiagnostics(
            bubbleCount: bubbleOrder.count,
            appliedCommandCount: commands.count,
            candidatePairCount: broadPhase.diagnostics.candidatePairCount,
            contactPairCount: contactGraph.contacts.count
        )
        return WorldStepReport(
            fixedTimeStep: configuration.fixedTimeStep,
            appliedCommandCount: commands.count,
            diagnostics: diagnostics
        )
    }

    private mutating func predictPositions(forces: [BubbleID: Vector2]) {
        let timeStep = configuration.fixedTimeStep
        let damping = max(0, min(configuration.linearDamping, 1))
        for id in bubbleOrder {
            guard let state = states[id] else { continue }
            let acceleration = gravity + (forces[id] ?? .zero) * (1 / Float(state.boundaryIndices.count + 1))
            for index in [state.centerIndex] + state.boundaryIndices {
                var particle = particles[index]
                let velocity = (particle.position - particle.previousPosition) * (1 - damping)
                particle.previousPosition = particle.position
                particle.position = particle.position + velocity + acceleration * (timeStep * timeStep)
                particles[index] = particle
            }
        }
    }

    private mutating func solveConstraints() {
        for id in bubbleOrder {
            guard var state = states[id] else { continue }
            for offset in state.distanceConstraints.indices {
                state.distanceConstraints[offset].resetMultiplier()
            }
            state.areaConstraint.resetMultiplier()
            states[id] = state
        }

        var activeContacts: Set<BubblePair> = []
        for _ in 0..<configuration.solverIterations {
            for id in bubbleOrder {
                guard var state = states[id] else { continue }
                for offset in state.distanceConstraints.indices {
                    state.distanceConstraints[offset].project(particles: &particles, timeStep: configuration.fixedTimeStep)
                }
                state.areaConstraint.project(particles: &particles, timeStep: configuration.fixedTimeStep)
                if let bounds {
                    WorldBoundaryConstraint(bounds: bounds).project(particles: &particles, indices: [state.centerIndex] + state.boundaryIndices)
                }
                states[id] = state
            }
            for pair in contactGraph.pairs {
                guard let first = states[pair.first], let second = states[pair.second] else { continue }
                let contacts = BubbleContactGenerator.contacts(between: topology(for: first, id: pair.first), and: topology(for: second, id: pair.second))
                guard !contacts.isEmpty else { continue }
                activeContacts.insert(pair)
                for contact in contacts {
                    var constraint = ContactConstraint(
                        first: first.boundaryIndices[contact.firstVertex],
                        second: second.boundaryIndices[contact.secondVertex],
                        normal: contact.normal,
                        penetration: contact.penetration
                    )
                    constraint.project(particles: &particles, timeStep: configuration.fixedTimeStep)
                }
            }
            solvePolygonContacts()
        }
        contactGraph.synchronizeContacts(with: activeContacts)
    }

    private mutating func synchronizeBroadPhase() {
        for id in bubbleOrder {
            guard let state = states[id], let bounds = AABB.enclosing(state.boundaryIndices.map { particles[$0].position }) else { continue }
            broadPhase.upsert(id, bounds: bounds)
        }
        contactGraph.synchronize(with: broadPhase.candidatePairs)
    }

    private mutating func solvePolygonContacts() {
        for polygonID in polygonOrder {
            guard let polygon = polygons[polygonID], let polygonBounds = polygon.worldBounds else { continue }
            for bubbleID in bubbleOrder {
                guard let state = states[bubbleID],
                      let bubbleBounds = AABB.enclosing(state.boundaryIndices.map({ particles[$0].position })),
                      bubbleBounds.intersects(polygonBounds)
                else { continue }
                let contacts = PolygonContactGenerator.contacts(bubble: topology(for: state, id: bubbleID), polygon: polygon)
                for contact in contacts {
                    PolygonContactConstraint(
                        particleIndex: state.boundaryIndices[contact.bubbleVertex],
                        normal: contact.normal,
                        penetration: contact.penetration,
                        surfaceVelocity: contact.surfaceVelocity
                    ).project(particles: &particles, timeStep: configuration.fixedTimeStep)
                }
            }
        }
    }

    private func topology(for state: BubbleState, id: BubbleID) -> BubbleTopology {
        BubbleTopology(
            id: id,
            center: particles[state.centerIndex].position,
            restArea: state.restArea,
            boundaryPoints: state.boundaryIndices.map { particles[$0].position }
        )
    }
}

private extension AABB {
    func intersects(_ other: AABB) -> Bool {
        minimum.x <= other.maximum.x && maximum.x >= other.minimum.x && minimum.y <= other.maximum.y && maximum.y >= other.minimum.y
    }
}
