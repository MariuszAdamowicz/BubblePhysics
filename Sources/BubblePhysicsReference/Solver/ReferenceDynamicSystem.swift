public struct ReferenceDynamicContact: Sendable, Equatable {
    public var indexA: Int
    public var indexB: Int?
    public var pointQ: ReferenceVector2?
    public var contactDistance: Float
    public var normalFallback: ReferenceVector2

    public init(
        indexA: Int,
        indexB: Int?,
        pointQ: ReferenceVector2?,
        contactDistance: Float,
        normalFallback: ReferenceVector2
    ) {
        self.indexA = indexA
        self.indexB = indexB
        self.pointQ = pointQ
        self.contactDistance = contactDistance
        self.normalFallback = normalFallback
    }
}

enum ReferenceContactResponse {
    static func effectiveMass(_ massA: Float, _ massB: Float?) -> Float {
        let safeA = max(massA, Float.leastNonzeroMagnitude)
        guard let massB else { return safeA }
        let safeB = max(massB, Float.leastNonzeroMagnitude)
        return (safeA * safeB) / (safeA + safeB)
    }

    static func coefficients(
        massA: Float,
        massB: Float?,
        stiffnessPerUnitMass: Float,
        dampingPerUnitMass: Float
    ) -> (stiffness: Float, damping: Float) {
        let mass = effectiveMass(massA, massB)
        return (
            max(0, stiffnessPerUnitMass) * mass,
            max(0, dampingPerUnitMass) * mass
        )
    }
}

public struct ReferenceDynamicSystem: Sendable {
    private let startCenters: [ReferenceVector2]
    private let startVelocities: [ReferenceVector2]
    private let masses: [Float]
    private let radii: [Float]
    private let contacts: [ReferenceDynamicContact]
    private let timeStep: Float
    private let stiffness: Float
    private let contactDamping: Float
    private let globalDrag: Float

    public init(
        startCenters: [ReferenceVector2],
        startVelocities: [ReferenceVector2],
        masses: [Float],
        radii: [Float],
        contacts: [ReferenceDynamicContact],
        timeStep: Float,
        stiffness: Float,
        contactDamping: Float,
        globalDrag: Float
    ) {
        precondition(startCenters.count == startVelocities.count)
        precondition(startCenters.count == masses.count)
        precondition(startCenters.count == radii.count)
        precondition(timeStep > 0 && timeStep.isFinite)
        self.startCenters = startCenters
        self.startVelocities = startVelocities
        self.masses = masses.map { max($0, Float.leastNonzeroMagnitude) }
        self.radii = radii
        self.contacts = contacts
        self.timeStep = timeStep
        self.stiffness = max(0, stiffness)
        self.contactDamping = max(0, contactDamping)
        self.globalDrag = max(0, globalDrag)
    }

    public func velocities(forEndCenters endCenters: [ReferenceVector2]) -> [ReferenceVector2] {
        precondition(endCenters.count == startCenters.count)
        let scale = 2 / timeStep
        return endCenters.indices.map { index in
            (endCenters[index] - startCenters[index]) * scale - startVelocities[index]
        }
    }

    public func residual(endCenters: [ReferenceVector2]) -> [ReferenceVector2] {
        precondition(endCenters.count == startCenters.count)
        let endVelocities = velocities(forEndCenters: endCenters)
        let midpointCenters = endCenters.indices.map { (startCenters[$0] + endCenters[$0]) * 0.5 }
        let midpointVelocities = endVelocities.indices.map {
            (startVelocities[$0] + endVelocities[$0]) * 0.5
        }
        var forces = midpointVelocities.indices.map {
            -midpointVelocities[$0] * (globalDrag * masses[$0])
        }

        for contact in contacts {
            guard midpointCenters.indices.contains(contact.indexA) else { continue }
            let indexA = contact.indexA
            let indexB = contact.indexB.flatMap { midpointCenters.indices.contains($0) ? $0 : nil }
            let response = ReferenceContactResponse.coefficients(
                massA: masses[indexA],
                massB: indexB.map { masses[$0] },
                stiffnessPerUnitMass: stiffness,
                dampingPerUnitMass: contactDamping
            )
            let sample = ReferenceContactSpringState.evaluate(
                centerA: midpointCenters[indexA],
                velocityA: midpointVelocities[indexA],
                radiusA: radii[indexA],
                centerB: indexB.map { midpointCenters[$0] },
                velocityB: indexB.map { midpointVelocities[$0] } ?? .zero,
                pointQ: contact.pointQ,
                normalFallback: contact.normalFallback,
                contactDistance: contact.contactDistance,
                stiffness: response.stiffness,
                damping: response.damping
            )
            forces[indexA] = forces[indexA] + sample.forceOnA
            if let indexB {
                forces[indexB] = forces[indexB] - sample.forceOnA
            }
        }

        return endCenters.indices.map { index in
            let momentumChange = (endVelocities[index] - startVelocities[index]) * masses[index]
            return momentumChange - forces[index] * timeStep
        }
    }

    public func applyJacobian(
        at endCenters: [ReferenceVector2],
        to vector: [ReferenceVector2]
    ) -> [ReferenceVector2] {
        precondition(endCenters.count == startCenters.count)
        precondition(vector.count == startCenters.count)
        guard vector.contains(where: { $0.lengthSquared > 0 }) else {
            return Array(repeating: .zero, count: vector.count)
        }

        let epsilon: Float = 1e-3
        let plus = zip(endCenters, vector).map { $0 + $1 * epsilon }
        let minus = zip(endCenters, vector).map { $0 - $1 * epsilon }
        return zip(residual(endCenters: plus), residual(endCenters: minus)).map {
            ($0 - $1) / (2 * epsilon)
        }
    }

    public func inverseDiagonalPreconditioner(
        at endCenters: [ReferenceVector2]
    ) -> [ReferenceVector2] {
        precondition(endCenters.count == startCenters.count)
        var diagonal = masses.map { $0 * (2 / timeStep + globalDrag) }
        for contact in contacts {
            guard diagonal.indices.contains(contact.indexA) else { continue }
            let indexB = contact.indexB.flatMap { diagonal.indices.contains($0) ? $0 : nil }
            let response = ReferenceContactResponse.coefficients(
                massA: masses[contact.indexA],
                massB: indexB.map { masses[$0] },
                stiffnessPerUnitMass: stiffness,
                dampingPerUnitMass: contactDamping
            )
            let contactContribution = timeStep * response.stiffness * 0.5 + response.damping
            guard contactContribution > 0 else { continue }
            diagonal[contact.indexA] += contactContribution
            if let indexB {
                diagonal[indexB] += contactContribution
            }
        }
        return diagonal.map {
            let inverse = 1 / max($0, Float.leastNonzeroMagnitude)
            return .init(x: inverse, y: inverse)
        }
    }
}
