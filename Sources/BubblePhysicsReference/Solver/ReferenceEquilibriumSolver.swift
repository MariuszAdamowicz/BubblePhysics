import Foundation

public enum ReferenceEquilibriumSolver {
    public static func solve(
        bubbles: inout [ReferenceBubble], segments: [ReferenceSegment], contacts: inout ReferenceContactSet,
        configuration: ReferenceConfiguration, candidatePairs: [ReferencePair]? = nil
    ) -> ReferenceSolverReport {
        let config = configuration.sanitized
        let indices = Dictionary(uniqueKeysWithValues: bubbles.indices.map { (bubbles[$0].id, $0) })
        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let predicted = bubbles.map(\.center)
        var ordered = contacts.contacts
        var totalPCG = 0
        var initialResidual: Float = 0
        var finalResidual: Float = 0
        var maxRelative: Float = 0
        var lineSearchFailures = 0
        var iterations = 0
        var nonFinite = false

        for outer in 0..<config.solverIterations {
            iterations = outer + 1
            let previousIDs = ordered.map(\.id)
            let build = buildStressState(bubbles: &bubbles, contacts: ordered, indices: indices,
                                         segments: segmentMap, configuration: config)
            ordered = build.contacts
            maxRelative = max(maxRelative, build.maximumRelativeDeformation)
            let system = ReferenceStressSystem(
                masses: bubbles.map(\.mass), predictedCenters: predicted, linearizationCenters: bubbles.map(\.center),
                timeStep: config.timeStep, contributions: build.contributions
            )
            let residual = system.residual(centers: bubbles.map(\.center))
            let residualNorm = vectorNorm(residual)
            if outer == 0 { initialResidual = residualNorm }
            finalResidual = residualNorm
            guard residualNorm.isFinite else { nonFinite = true; break }
            if residualNorm <= config.stressTolerance && previousIDs == ordered.map(\.id) { break }

            let pcg = ReferencePCGSolver.solve(
                rightHandSide: residual.map { -$0 }, apply: system.applyJacobian,
                inverseDiagonal: system.inverseDiagonalPreconditioner(), tolerance: config.pcgTolerance,
                iterationLimit: config.pcgIterationLimit
            )
            totalPCG += pcg.iterationCount
            nonFinite = nonFinite || pcg.hasNonFiniteState
            let oldCenters = bubbles.map(\.center)
            let oldEnergy = energy(centers: oldCenters, predicted: predicted, bubbles: bubbles, contacts: ordered,
                                   indices: indices, segments: segmentMap, configuration: config)
            var accepted = false
            var acceptedStep: Float = 0
            for lambda: Float in [1, 0.5, 0.25, 0.125, 0.0625, 0.03125] {
                let trial = zip(oldCenters, pcg.solution).map { $0 + $1 * lambda }
                guard trial.allSatisfy(\.isFinite) else { continue }
                let trialEnergy = energy(centers: trial, predicted: predicted, bubbles: bubbles, contacts: ordered,
                                         indices: indices, segments: segmentMap, configuration: config)
                if trialEnergy <= oldEnergy {
                    for index in bubbles.indices { bubbles[index].center = trial[index] }
                    accepted = true
                    acceptedStep = zip(oldCenters, trial).map { ($1 - $0).length }.max() ?? 0
                    break
                }
            }
            if !accepted { lineSearchFailures += 1 }

            let candidates = regeneratedCandidates(bubbles: bubbles, segments: segments, existingContacts: ordered,
                                                   candidatePairs: candidatePairs, bubbleIndices: indices)
            contacts.update(candidates: candidates, bubbles: bubbles, segments: segments, configuration: config)
            ordered = contacts.contacts
            if previousIDs == ordered.map(\.id) && acceptedStep <= config.positionTolerance
                && residualNorm <= config.stressTolerance { break }
        }

        let finalBuild = buildStressState(bubbles: &bubbles, contacts: ordered, indices: indices,
                                          segments: segmentMap, configuration: config)
        ordered = finalBuild.contacts
        contacts.replaceContacts(ordered)
        maxRelative = max(maxRelative, finalBuild.maximumRelativeDeformation)
        let finalSystem = ReferenceStressSystem(
            masses: bubbles.map(\.mass), predictedCenters: predicted, linearizationCenters: bubbles.map(\.center),
            timeStep: config.timeStep, contributions: finalBuild.contributions
        )
        finalResidual = vectorNorm(finalSystem.residual(centers: bubbles.map(\.center)))
        nonFinite = nonFinite || !finalResidual.isFinite || bubbles.contains { !$0.center.isFinite }
        let maximumPenetration = max(0, ordered.map(\.penetration).max() ?? 0)
        let converged = finalResidual <= config.stressTolerance && !nonFinite
        return ReferenceSolverReport(
            iterations: iterations, maximumPenetration: maximumPenetration, converged: converged,
            didReachIterationLimit: !converged && iterations >= config.solverIterations,
            positionCorrectionCount: 0, deformationCount: bubbles.reduce(0) { $0 + $1.directionalDeformations.count },
            pcgIterationCount: totalPCG, initialResidualNorm: initialResidual, finalResidualNorm: finalResidual,
            maximumRelativeDeformation: maxRelative, lineSearchFailureCount: lineSearchFailures,
            hasNonFiniteState: nonFinite
        )
    }

    private struct StressBuild {
        var contacts: [ReferenceContact]
        var contributions: [ReferenceStressContribution]
        var maximumRelativeDeformation: Float
    }

    private static func buildStressState(
        bubbles: inout [ReferenceBubble], contacts: [ReferenceContact], indices: [ReferenceBubbleID: Int],
        segments: [ReferenceSegmentID: ReferenceSegment], configuration: ReferenceConfiguration
    ) -> StressBuild {
        for index in bubbles.indices { bubbles[index].directionalDeformations.removeAll(keepingCapacity: true) }
        var updated: [ReferenceContact] = []
        var contributions: [ReferenceStressContribution] = []
        var maximumRelative: Float = 0
        for var contact in contacts.sorted(by: { $0.id < $1.id }) {
            guard let indexA = indices[contact.bubbleA] else { continue }
            switch contact.kind {
            case .bubbleBubble:
                guard let idB = contact.bubbleB, let indexB = indices[idB] else { continue }
                let delta = bubbles[indexB].center - bubbles[indexA].center
                let fallback = bubbles[indexA].id <= bubbles[indexB].id
                    ? ReferenceVector2(x: 1, y: 0) : ReferenceVector2(x: -1, y: 0)
                let normal = delta.normalized(or: fallback)
                let compression = max(0, bubbles[indexA].targetRadius + bubbles[indexB].targetRadius - delta.length)
                guard compression > configuration.contactTolerance || contact.age > 0 else { continue }
                var stress = ReferenceDeformationLaw.solve(
                    requiredCompression: compression, radiusA: bubbles[indexA].targetRadius,
                    stiffnessA: bubbles[indexA].stiffness, radiusB: bubbles[indexB].targetRadius,
                    stiffnessB: bubbles[indexB].stiffness, nonlinearStiffening: configuration.nonlinearStiffening)
                stress.pressure = min(stress.pressure, configuration.maximumContactPressure)
                contact.normal = normal
                if compression > configuration.contactTolerance { contact.penetration = compression }
                apply(stress, to: &contact)
                addDeformation(&bubbles[indexA], contact: contact, direction: normal, depth: stress.compressionA)
                addDeformation(&bubbles[indexB], contact: contact, direction: -normal, depth: stress.compressionB)
                contributions.append(.init(indexA: indexA, indexB: indexB, normal: normal,
                                           pressure: stress.pressure, effectiveStiffness: stress.effectiveStiffness))
                maximumRelative = max(maximumRelative, stress.compressionA / bubbles[indexA].targetRadius,
                                      stress.compressionB / bubbles[indexB].targetRadius)
            case .bubbleSegment:
                guard let segmentID = contact.segment, let segment = segments[segmentID] else { continue }
                let candidate = ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(bubbles[indexA], segment)
                let compression = max(0, bubbles[indexA].targetRadius - (bubbles[indexA].center - candidate.pointQ).length)
                guard compression > configuration.contactTolerance || contact.age > 0 else { continue }
                var stress = ReferenceDeformationLaw.solve(requiredCompression: compression,
                    radiusA: bubbles[indexA].targetRadius, stiffnessA: bubbles[indexA].stiffness,
                    nonlinearStiffening: configuration.nonlinearStiffening)
                stress.pressure = min(stress.pressure, configuration.maximumContactPressure)
                contact.normal = candidate.normal; contact.pointQ = candidate.pointQ
                if compression > configuration.contactTolerance { contact.penetration = compression }
                apply(stress, to: &contact)
                addDeformation(&bubbles[indexA], contact: contact, direction: -candidate.normal, depth: stress.compressionA)
                contributions.append(.init(indexA: indexA, indexB: nil, normal: -candidate.normal,
                                           pressure: stress.pressure, effectiveStiffness: stress.effectiveStiffness))
                maximumRelative = max(maximumRelative, stress.compressionA / bubbles[indexA].targetRadius)
            }
            updated.append(contact)
        }
        return .init(contacts: updated, contributions: contributions, maximumRelativeDeformation: maximumRelative)
    }

    private static func apply(_ stress: ReferenceContactStress, to contact: inout ReferenceContact) {
        contact.compressionA = stress.compressionA; contact.compressionB = stress.compressionB
        contact.pressure = stress.pressure; contact.effectiveStiffness = stress.effectiveStiffness
        contact.accumulatedCompression = stress.compressionA + stress.compressionB
    }

    private static func addDeformation(
        _ bubble: inout ReferenceBubble, contact: ReferenceContact, direction: ReferenceVector2, depth: Float
    ) {
        guard depth > 0 else { return }
        bubble.directionalDeformations.append(.init(contactID: contact.id, direction: direction,
            depth: min(depth, bubble.targetRadius), angularWidth: .pi / 2, pressure: contact.pressure))
    }

    private static func energy(
        centers: [ReferenceVector2], predicted: [ReferenceVector2], bubbles: [ReferenceBubble],
        contacts: [ReferenceContact], indices: [ReferenceBubbleID: Int], segments: [ReferenceSegmentID: ReferenceSegment],
        configuration: ReferenceConfiguration
    ) -> Float {
        let invDt2 = 1 / max(configuration.timeStep * configuration.timeStep, Float.ulpOfOne)
        var total: Float = 0
        for index in centers.indices {
            total += 0.5 * bubbles[index].mass * invDt2 * (centers[index] - predicted[index]).lengthSquared
        }
        for contact in contacts {
            guard let a = indices[contact.bubbleA] else { continue }
            if let idB = contact.bubbleB, let b = indices[idB] {
                let depth = max(0, bubbles[a].targetRadius + bubbles[b].targetRadius - (centers[b] - centers[a]).length)
                let stress = ReferenceDeformationLaw.solve(requiredCompression: depth,
                    radiusA: bubbles[a].targetRadius, stiffnessA: bubbles[a].stiffness,
                    radiusB: bubbles[b].targetRadius, stiffnessB: bubbles[b].stiffness,
                    nonlinearStiffening: configuration.nonlinearStiffening)
                total += deformationEnergy(stress.compressionA, bubbles[a], configuration.nonlinearStiffening)
                    + deformationEnergy(stress.compressionB, bubbles[b], configuration.nonlinearStiffening)
            } else if let segmentID = contact.segment, let segment = segments[segmentID] {
                let q = closestPoint(to: centers[a], on: .init(a: segment.currentA, b: segment.currentB)).point
                total += deformationEnergy(max(0, bubbles[a].targetRadius - (centers[a] - q).length),
                                           bubbles[a], configuration.nonlinearStiffening)
            }
        }
        return total.isFinite ? total : Float.greatestFiniteMagnitude
    }

    private static func deformationEnergy(_ depth: Float, _ bubble: ReferenceBubble, _ alpha: Float) -> Float {
        let square = depth * depth
        return 0.5 * bubble.stiffness * square + 0.25 * bubble.stiffness * alpha * square * square
            / max(bubble.targetRadius * bubble.targetRadius, Float.ulpOfOne)
    }

    private static func vectorNorm(_ values: [ReferenceVector2]) -> Float {
        values.reduce(0) { $0 + $1.lengthSquared }.squareRoot()
    }

    private static func regeneratedCandidates(
        bubbles: [ReferenceBubble], segments: [ReferenceSegment], existingContacts: [ReferenceContact],
        candidatePairs: [ReferencePair]?, bubbleIndices: [ReferenceBubbleID: Int]
    ) -> [ReferenceContact] {
        // Deformation yields the target envelope; it must not erase its own stress contact.
        var geometryBubbles = bubbles
        for index in geometryBubbles.indices { geometryBubbles[index].directionalDeformations.removeAll() }
        var result: [ReferenceContact] = []
        var pairs = Set(candidatePairs ?? [])
        for contact in existingContacts where contact.kind == .bubbleBubble {
            if let b = contact.bubbleB { pairs.insert(.init(.init(rawValue: contact.bubbleA.rawValue), .init(rawValue: b.rawValue))) }
        }
        if candidatePairs != nil {
            var broad = SweepAndPruneBroadPhase()
            pairs.formUnion(broad.candidatePairs(for: geometryBubbles.map { .init(id: .init(rawValue: $0.id.rawValue), bounds: $0.targetBounds) }))
        }
        for pair in pairs.sorted() {
            guard let a = bubbleIndices[.init(rawValue: pair.first.rawValue)],
                  let b = bubbleIndices[.init(rawValue: pair.second.rawValue)] else { continue }
            result.append(ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(geometryBubbles[a], geometryBubbles[b]))
        }
        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        if candidatePairs != nil {
            for segment in segments { for bubble in geometryBubbles { result.append(ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(bubble, segment)) } }
        } else {
            for contact in existingContacts where contact.kind == .bubbleSegment {
                if let id = contact.segment, let segment = segmentMap[id], let index = bubbleIndices[contact.bubbleA] {
                    result.append(ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(geometryBubbles[index], segment))
                }
            }
        }
        return result
    }
}
