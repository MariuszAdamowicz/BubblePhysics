import Foundation

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
    public let timings: WorldStepTimings

    public init(fixedTimeStep: Float, appliedCommandCount: Int, diagnostics: WorldDiagnostics, timings: WorldStepTimings) {
        self.fixedTimeStep = fixedTimeStep
        self.appliedCommandCount = appliedCommandCount
        self.diagnostics = diagnostics
        self.timings = timings
    }

    public static func == (lhs: WorldStepReport, rhs: WorldStepReport) -> Bool {
        lhs.fixedTimeStep == rhs.fixedTimeStep &&
            lhs.appliedCommandCount == rhs.appliedCommandCount &&
            lhs.diagnostics == rhs.diagnostics
    }
}

public struct WorldStepTimings: Equatable, Sendable {
    public let predictionMilliseconds: Double
    public let constraintMilliseconds: Double
    public let shapeConstraintMilliseconds: Double
    public let bubbleContactMilliseconds: Double
    public let auxiliaryConstraintMilliseconds: Double
    public let broadPhaseMilliseconds: Double
    public let totalMilliseconds: Double

    public init(predictionMilliseconds: Double, constraintMilliseconds: Double, shapeConstraintMilliseconds: Double, bubbleContactMilliseconds: Double, auxiliaryConstraintMilliseconds: Double, broadPhaseMilliseconds: Double, totalMilliseconds: Double) {
        self.predictionMilliseconds = predictionMilliseconds
        self.constraintMilliseconds = constraintMilliseconds
        self.shapeConstraintMilliseconds = shapeConstraintMilliseconds
        self.bubbleContactMilliseconds = bubbleContactMilliseconds
        self.auxiliaryConstraintMilliseconds = auxiliaryConstraintMilliseconds
        self.broadPhaseMilliseconds = broadPhaseMilliseconds
        self.totalMilliseconds = totalMilliseconds
    }
}

private struct BubbleState: Sendable {
    var restArea: Float
    let centerIndex: Int
    let boundaryIndices: [Int]
    var distanceConstraints: [DistanceConstraint]
    var areaConstraint: AreaConstraint
}

private struct ConstraintPhaseTimings: Sendable {
    var shapeMilliseconds: Double = 0
    var bubbleContactMilliseconds: Double = 0
    var auxiliaryMilliseconds: Double = 0
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
    private var grabs: [GrabID: GrabState] = [:]
    private var nextGrabIdentifier = 1
    public private(set) var operationEvents: [BubbleOperationEvent] = []

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

    public func simulationSnapshot() -> SimulationWorldSnapshot {
        SimulationWorldSnapshot(
            particles: particles.particles.map {
                SimulationParticleSnapshot(
                    position: $0.position,
                    previousPosition: $0.previousPosition,
                    inverseMass: $0.inverseMass
                )
            },
            bubbles: bubbleOrder.compactMap { id in
                guard let state = states[id] else { return nil }
                return SimulationBubbleSnapshot(
                    id: id,
                    centerIndex: state.centerIndex,
                    boundaryIndices: state.boundaryIndices,
                    restArea: state.restArea
                )
            },
            distanceConstraints: bubbleOrder.compactMap { states[$0] }.flatMap { state in
                return state.distanceConstraints.map {
                    SimulationDistanceConstraintSnapshot(
                        firstIndex: $0.first,
                        secondIndex: $0.second,
                        restLength: $0.restLength,
                        compliance: $0.compliance
                    )
                }
            },
            areaConstraints: bubbleOrder.compactMap { id in
                guard let state = states[id] else { return nil }
                return SimulationAreaConstraintSnapshot(
                    boundaryIndices: state.areaConstraint.indices,
                    restArea: state.areaConstraint.restArea,
                    compliance: state.areaConstraint.compliance
                )
            },
            configuration: configuration,
            bounds: bounds,
            polygons: polygonOrder.compactMap { id in
                guard let polygon = polygons[id] else { return nil }
                return SimulationPolygonSnapshot(id: id, mode: polygon.mode, worldVertices: polygon.worldVertices, position: polygon.position, linearVelocity: polygon.linearVelocity, angularVelocity: polygon.angularVelocity)
            },
            grabs: grabs.values.sorted { $0.id.rawValue < $1.id.rawValue }.map {
                SimulationGrabSnapshot(id: $0.id, bubbleID: $0.bubbleID, target: $0.target, resistance: $0.resistance)
            }
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
    public mutating func beginGrab(bubbleID: BubbleID, target: Vector2) -> GrabID? {
        guard states[bubbleID] != nil else { return nil }
        let id = GrabID(rawValue: nextGrabIdentifier)
        nextGrabIdentifier += 1
        grabs[id] = GrabState(id: id, bubbleID: bubbleID, target: target)
        return id
    }

    public mutating func moveGrabTarget(_ id: GrabID, to target: Vector2) {
        guard var grab = grabs[id] else { return }
        grab.update(target: target, resistance: grab.resistance)
        grabs[id] = grab
    }

    public mutating func endGrab(_ id: GrabID) {
        grabs.removeValue(forKey: id)
    }

    public func grabState(_ id: GrabID) -> GrabState? { grabs[id] }

    @discardableResult
    public mutating func resizeBubble(_ id: BubbleID, toRestArea restArea: Float) -> Bool {
        guard restArea > 0, var state = states[id] else { return false }
        let scale = sqrt(restArea / state.restArea)
        let center = particles[state.centerIndex].position
        for index in state.boundaryIndices {
            var particle = particles[index]
            particle.position = center + (particle.position - center) * scale
            particle.previousPosition = center + (particle.previousPosition - center) * scale
            particles[index] = particle
        }
        state.restArea = restArea
        state.areaConstraint = AreaConstraint(indices: state.boundaryIndices, restArea: restArea)
        states[id] = state
        operationEvents.append(.resized(id, restArea: restArea))
        synchronizeBroadPhase()
        return true
    }

    @discardableResult
    public mutating func merge(_ first: BubbleID, _ second: BubbleID) -> BubbleID? {
        guard let firstState = states[first], let secondState = states[second], first != second else { return nil }
        let firstCenter = particles[firstState.centerIndex].position
        let secondCenter = particles[secondState.centerIndex].position
        let area = firstState.restArea + secondState.restArea
        let center = (firstCenter * firstState.restArea + secondCenter * secondState.restArea) * (1 / area)
        removeBubble(first)
        removeBubble(second)
        let output = addBubble(center: center, restArea: area)
        operationEvents.append(.merged(inputs: [min(first, second), max(first, second)], output: output))
        return output
    }

    @discardableResult
    public mutating func split(_ id: BubbleID) -> [BubbleID]? {
        guard let state = states[id] else { return nil }
        let center = particles[state.centerIndex].position
        let area = state.restArea * 0.5
        let offset = sqrt(area / .pi) * 0.5
        removeBubble(id)
        let outputs = [
            addBubble(center: center + Vector2(x: -offset, y: 0), restArea: area),
            addBubble(center: center + Vector2(x: offset, y: 0), restArea: area)
        ]
        operationEvents.append(.split(input: id, outputs: outputs))
        return outputs
    }

    @discardableResult
    public mutating func step() -> WorldStepReport {
        let totalStart = Date()
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

        let predictionStart = Date()
        predictPositions(forces: forces)
        let constraintStart = Date()
        let constraintPhaseTimings = solveConstraints()
        let broadPhaseStart = Date()
        synchronizeBroadPhase()
        let totalEnd = Date()

        let diagnostics = WorldDiagnostics(
            bubbleCount: bubbleOrder.count,
            appliedCommandCount: commands.count,
            candidatePairCount: broadPhase.diagnostics.candidatePairCount,
            contactPairCount: contactGraph.contacts.count
        )
        let timings = WorldStepTimings(
            predictionMilliseconds: constraintStart.timeIntervalSince(predictionStart) * 1_000,
            constraintMilliseconds: broadPhaseStart.timeIntervalSince(constraintStart) * 1_000,
            shapeConstraintMilliseconds: constraintPhaseTimings.shapeMilliseconds,
            bubbleContactMilliseconds: constraintPhaseTimings.bubbleContactMilliseconds,
            auxiliaryConstraintMilliseconds: constraintPhaseTimings.auxiliaryMilliseconds,
            broadPhaseMilliseconds: totalEnd.timeIntervalSince(broadPhaseStart) * 1_000,
            totalMilliseconds: totalEnd.timeIntervalSince(totalStart) * 1_000
        )
        return WorldStepReport(
            fixedTimeStep: configuration.fixedTimeStep,
            appliedCommandCount: commands.count,
            diagnostics: diagnostics,
            timings: timings
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

    private mutating func solveConstraints() -> ConstraintPhaseTimings {
        var timings = ConstraintPhaseTimings()
        let resetStart = Date()
        for id in bubbleOrder {
            guard var state = states[id] else { continue }
            for offset in state.distanceConstraints.indices {
                state.distanceConstraints[offset].resetMultiplier()
            }
            state.areaConstraint.resetMultiplier()
            states[id] = state
        }
        timings.shapeMilliseconds += Date().timeIntervalSince(resetStart) * 1_000

        var activeContacts: Set<BubblePair> = []
        let candidatePairs = contactGraph.pairs
        for _ in 0..<configuration.solverIterations {
            let shapeStart = Date()
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
            timings.shapeMilliseconds += Date().timeIntervalSince(shapeStart) * 1_000

            let bubbleContactStart = Date()
            for pair in candidatePairs {
                guard let first = states[pair.first], let second = states[pair.second] else { continue }
                let contacts = BubbleContactGenerator.contacts(
                    firstCenter: particles[first.centerIndex].position,
                    firstBoundaryIndices: first.boundaryIndices,
                    secondCenter: particles[second.centerIndex].position,
                    secondBoundaryIndices: second.boundaryIndices,
                    particles: particles.particles
                )
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
            timings.bubbleContactMilliseconds += Date().timeIntervalSince(bubbleContactStart) * 1_000

            let auxiliaryStart = Date()
            solvePolygonContacts()
            solveGrabs()
            timings.auxiliaryMilliseconds += Date().timeIntervalSince(auxiliaryStart) * 1_000
        }
        contactGraph.synchronizeContacts(with: activeContacts)
        return timings
    }

    private mutating func synchronizeBroadPhase() {
        var updates: [(BubbleID, AABB)] = []
        updates.reserveCapacity(bubbleOrder.count)
        for id in bubbleOrder {
            guard let state = states[id], let bounds = AABB.enclosing(state.boundaryIndices.map { particles[$0].position }) else { continue }
            updates.append((id, bounds))
        }
        broadPhase.upsert(updates)
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

    private mutating func solveGrabs() {
        for id in grabs.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var grab = grabs[id], let state = states[grab.bubbleID] else { continue }
            let resistance = GrabConstraint(
                particleIndex: state.centerIndex,
                target: grab.target,
                maximumCorrection: 1.5
            ).project(particles: &particles)
            grab.update(target: grab.target, resistance: resistance)
            grabs[id] = grab
        }
    }

    private mutating func removeBubble(_ id: BubbleID) {
        states.removeValue(forKey: id)
        bubbleOrder.removeAll { $0 == id }
        broadPhase.remove(id)
        grabs = grabs.filter { $0.value.bubbleID != id }
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
