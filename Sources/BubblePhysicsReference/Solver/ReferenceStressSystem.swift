public struct ReferenceStressContribution: Sendable, Equatable {
    public var indexA: Int
    public var indexB: Int?
    public var normal: ReferenceVector2
    public var pressure: Float
    public var effectiveStiffness: Float

    public init(indexA: Int, indexB: Int?, normal: ReferenceVector2, pressure: Float, effectiveStiffness: Float) {
        self.indexA = indexA
        self.indexB = indexB
        self.normal = normal
        self.pressure = pressure
        self.effectiveStiffness = effectiveStiffness
    }
}

public struct ReferenceStressSystem: Sendable, Equatable {
    public var masses: [Float]
    public var predictedCenters: [ReferenceVector2]
    public var linearizationCenters: [ReferenceVector2]
    public var timeStep: Float
    public var contributions: [ReferenceStressContribution]

    public init(
        masses: [Float], predictedCenters: [ReferenceVector2], linearizationCenters: [ReferenceVector2],
        timeStep: Float, contributions: [ReferenceStressContribution]
    ) {
        self.masses = masses
        self.predictedCenters = predictedCenters
        self.linearizationCenters = linearizationCenters
        self.timeStep = timeStep
        self.contributions = contributions
    }

    public func residual(centers: [ReferenceVector2]) -> [ReferenceVector2] {
        let inverseDtSquared = 1 / max(timeStep * timeStep, Float.ulpOfOne)
        var result = centers.indices.map { index in
            (centers[index] - predictedCenters[index]) * (masses[index] * inverseDtSquared)
        }
        for contact in contributions where contact.indexA < result.count {
            let gradient = contact.normal * contact.pressure
            result[contact.indexA] = result[contact.indexA] + gradient
            if let indexB = contact.indexB, indexB < result.count {
                result[indexB] = result[indexB] - gradient
            }
        }
        return result
    }

    public func applyJacobian(to vector: [ReferenceVector2]) -> [ReferenceVector2] {
        let inverseDtSquared = 1 / max(timeStep * timeStep, Float.ulpOfOne)
        var result = vector.indices.map { index in vector[index] * (masses[index] * inverseDtSquared) }
        for contact in contributions where contact.indexA < result.count {
            let relative = contact.indexB.map { vector[contact.indexA] - vector[$0] } ?? vector[contact.indexA]
            let projected = contact.normal * (contact.effectiveStiffness * relative.dot(contact.normal))
            result[contact.indexA] = result[contact.indexA] + projected
            if let indexB = contact.indexB, indexB < result.count {
                result[indexB] = result[indexB] - projected
            }
        }
        return result
    }

    public func inverseDiagonalPreconditioner() -> [ReferenceVector2] {
        let inverseDtSquared = 1 / max(timeStep * timeStep, Float.ulpOfOne)
        var diagonal = masses.map {
            let value = max($0 * inverseDtSquared, Float.ulpOfOne)
            return ReferenceVector2(x: value, y: value)
        }
        for contact in contributions where contact.indexA < diagonal.count {
            let block = ReferenceVector2(
                x: contact.effectiveStiffness * contact.normal.x * contact.normal.x,
                y: contact.effectiveStiffness * contact.normal.y * contact.normal.y
            )
            diagonal[contact.indexA] = diagonal[contact.indexA] + block
            if let indexB = contact.indexB, indexB < diagonal.count { diagonal[indexB] = diagonal[indexB] + block }
        }
        return diagonal.map { .init(x: 1 / max($0.x, Float.ulpOfOne), y: 1 / max($0.y, Float.ulpOfOne)) }
    }
}
