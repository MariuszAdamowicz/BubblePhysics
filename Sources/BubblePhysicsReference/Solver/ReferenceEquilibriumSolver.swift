public enum ReferenceEquilibriumSolver {
    public static func solve(
        bubbles: inout [ReferenceBubble],
        segments: [ReferenceSegment],
        contacts: inout ReferenceContactSet,
        configuration: ReferenceConfiguration,
        candidatePairs: [ReferencePair]? = nil,
        timeStep: Float? = nil
    ) -> ReferenceSolverReport {
        let config = configuration.sanitized
        let dt = validTimeStep(timeStep ?? config.timeStep, fallback: config.timeStep)
        let startCenters = bubbles.map(\.center)
        let startVelocities = bubbles.map(\.velocity)
        let masses = bubbles.map(\.mass)
        let radii = bubbles.map(\.targetRadius)
        let indices = Dictionary(uniqueKeysWithValues: bubbles.indices.map { (bubbles[$0].id, $0) })
        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let newtonLimit = min(4, max(1, config.solverIterations))
        let pcgLimit = min(16, max(1, config.pcgIterationLimit))

        var endCenters = bubbles.indices.map { startCenters[$0] + startVelocities[$0] * dt }
        var activeContacts = refreshedContacts(
            previous: contacts.contacts, endCenters: endCenters, endVelocities: startVelocities,
            bubbles: bubbles, segments: segments, candidatePairs: candidatePairs,
            indices: indices, configuration: config
        )
        var initialResidual: Float = 0
        var finalResidual: Float = 0
        var totalPCG = 0
        var iterations = 0
        var lineSearchFailures = 0
        var nonFinite = false
        var converged = false

        for iteration in 0..<newtonLimit {
            iterations = iteration + 1
            let system = dynamicSystem(
                startCenters: startCenters, startVelocities: startVelocities,
                masses: masses, radii: radii, contacts: activeContacts,
                indices: indices, timeStep: dt, configuration: config
            )
            let residual = system.residual(endCenters: endCenters)
            let residualNorm = vectorNorm(residual)
            if iteration == 0 { initialResidual = residualNorm }
            finalResidual = residualNorm
            guard residualNorm.isFinite, endCenters.allSatisfy(\.isFinite) else {
                nonFinite = true
                break
            }
            if residualNorm <= config.stressTolerance {
                converged = true
                break
            }

            let pcg = ReferencePCGSolver.solve(
                rightHandSide: residual.map { -$0 },
                apply: { system.applyJacobian(at: endCenters, to: $0) },
                inverseDiagonal: system.inverseDiagonalPreconditioner(at: endCenters),
                tolerance: config.pcgTolerance,
                iterationLimit: pcgLimit
            )
            totalPCG += pcg.iterationCount
            nonFinite = nonFinite || pcg.hasNonFiniteState

            var acceptedCenters: [ReferenceVector2]?
            var acceptedContacts = activeContacts
            var acceptedNorm = residualNorm
            for lambda: Float in [1, 0.5, 0.25, 0.125, 0.0625, 0.03125] {
                let trial = zip(endCenters, pcg.solution).map { $0 + $1 * lambda }
                guard trial.allSatisfy(\.isFinite) else { continue }
                let trialVelocities = velocities(
                    startCenters: startCenters, startVelocities: startVelocities,
                    endCenters: trial, timeStep: dt
                )
                let trialContacts = refreshedContacts(
                    previous: activeContacts, endCenters: trial, endVelocities: trialVelocities,
                    bubbles: bubbles, segments: segments, candidatePairs: candidatePairs,
                    indices: indices, configuration: config
                )
                let trialSystem = dynamicSystem(
                    startCenters: startCenters, startVelocities: startVelocities,
                    masses: masses, radii: radii, contacts: trialContacts,
                    indices: indices, timeStep: dt, configuration: config
                )
                let trialNorm = vectorNorm(trialSystem.residual(endCenters: trial))
                if trialNorm.isFinite, trialNorm < acceptedNorm {
                    acceptedCenters = trial
                    acceptedContacts = trialContacts
                    acceptedNorm = trialNorm
                    break
                }
            }

            guard let acceptedCenters else {
                lineSearchFailures += 1
                break
            }
            endCenters = acceptedCenters
            activeContacts = acceptedContacts
            finalResidual = acceptedNorm
        }

        let endVelocities = velocities(
            startCenters: startCenters, startVelocities: startVelocities,
            endCenters: endCenters, timeStep: dt
        )
        let finalContacts = annotatedContacts(
            activeContacts, endCenters: endCenters, bubbles: bubbles,
            segments: segmentMap, indices: indices, configuration: config
        )
        contacts.replaceContacts(finalContacts)
        for index in bubbles.indices {
            bubbles[index].center = endCenters[index]
            bubbles[index].velocity = endVelocities[index]
        }

        let finalSystem = dynamicSystem(
            startCenters: startCenters, startVelocities: startVelocities,
            masses: masses, radii: radii, contacts: finalContacts,
            indices: indices, timeStep: dt, configuration: config
        )
        finalResidual = vectorNorm(finalSystem.residual(endCenters: endCenters))
        converged = converged || finalResidual <= config.stressTolerance
        nonFinite = nonFinite || !finalResidual.isFinite
            || bubbles.contains { !$0.center.isFinite || !$0.velocity.isFinite }
        let maximumCompression = finalContacts.map(\.accumulatedCompression).max() ?? 0
        let maximumRelative = finalContacts.compactMap { contact -> Float? in
            guard let index = indices[contact.bubbleA] else { return nil }
            return contact.compressionA / max(bubbles[index].targetRadius, Float.ulpOfOne)
        }.max() ?? 0

        return ReferenceSolverReport(
            iterations: iterations,
            maximumPenetration: maximumCompression,
            converged: converged && !nonFinite,
            didReachIterationLimit: !converged && iterations >= newtonLimit,
            positionCorrectionCount: 0,
            deformationCount: 0,
            pcgIterationCount: totalPCG,
            initialResidualNorm: initialResidual,
            finalResidualNorm: finalResidual,
            maximumRelativeDeformation: maximumRelative,
            lineSearchFailureCount: lineSearchFailures,
            hasNonFiniteState: nonFinite
        )
    }

    private static func dynamicSystem(
        startCenters: [ReferenceVector2],
        startVelocities: [ReferenceVector2],
        masses: [Float],
        radii: [Float],
        contacts: [ReferenceContact],
        indices: [ReferenceBubbleID: Int],
        timeStep: Float,
        configuration: ReferenceConfiguration
    ) -> ReferenceDynamicSystem {
        ReferenceDynamicSystem(
            startCenters: startCenters,
            startVelocities: startVelocities,
            masses: masses,
            radii: radii,
            contacts: contacts.compactMap { contact in
                guard let indexA = indices[contact.bubbleA] else { return nil }
                let indexB = contact.bubbleB.flatMap { indices[$0] }
                return ReferenceDynamicContact(
                    indexA: indexA,
                    indexB: indexB,
                    pointQ: indexB == nil ? contact.pointQ : nil,
                    contactDistance: indexB.map { radii[indexA] + radii[$0] } ?? radii[indexA],
                    normalFallback: indexB == nil ? contact.normal : -contact.normal
                )
            },
            timeStep: timeStep,
            stiffness: configuration.contactStiffness,
            contactDamping: configuration.contactDamping,
            globalDrag: configuration.linearDamping
        )
    }

    private static func refreshedContacts(
        previous: [ReferenceContact],
        endCenters: [ReferenceVector2],
        endVelocities: [ReferenceVector2],
        bubbles: [ReferenceBubble],
        segments: [ReferenceSegment],
        candidatePairs: [ReferencePair]?,
        indices: [ReferenceBubbleID: Int],
        configuration: ReferenceConfiguration
    ) -> [ReferenceContact] {
        var geometryBubbles = bubbles
        for index in geometryBubbles.indices {
            geometryBubbles[index].center = endCenters[index]
            geometryBubbles[index].velocity = endVelocities[index]
        }
        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var candidatesByID: [ReferenceContactID: ReferenceContact] = [:]

        for old in previous {
            guard let indexA = indices[old.bubbleA] else { continue }
            let candidate: ReferenceContact
            let separatingSpeed: Float
            switch old.kind {
            case .bubbleBubble:
                guard let idB = old.bubbleB, let indexB = indices[idB] else { continue }
                candidate = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(
                    geometryBubbles[indexA], geometryBubbles[indexB]
                )
                separatingSpeed = (endVelocities[indexB] - endVelocities[indexA]).dot(candidate.normal)
            case .bubbleSegment:
                guard let id = old.segment, let segment = segmentMap[id] else { continue }
                candidate = ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(geometryBubbles[indexA], segment)
                separatingSpeed = (endVelocities[indexA] - segment.linearVelocity).dot(candidate.normal)
            }
            let remainsNearSurface = candidate.penetration >= -configuration.separationTolerance
            if candidate.penetration > configuration.contactTolerance
                || (remainsNearSurface && separatingSpeed <= 0) {
                candidatesByID[candidate.id] = preservingHistory(candidate, from: old)
            }
        }

        if let candidatePairs {
            for pair in candidatePairs.sorted() {
                guard let indexA = indices[.init(rawValue: pair.first.rawValue)],
                      let indexB = indices[.init(rawValue: pair.second.rawValue)] else { continue }
                let candidate = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(
                    geometryBubbles[indexA], geometryBubbles[indexB]
                )
                if candidate.penetration > configuration.contactTolerance {
                    candidatesByID[candidate.id] = candidate
                }
            }
            for segment in segments {
                for bubble in geometryBubbles {
                    let candidate = ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(bubble, segment)
                    if candidate.penetration > configuration.contactTolerance {
                        candidatesByID[candidate.id] = candidate
                    }
                }
            }
        }
        return candidatesByID.values.sorted { $0.id < $1.id }
    }

    private static func preservingHistory(_ candidate: ReferenceContact, from old: ReferenceContact) -> ReferenceContact {
        var result = candidate
        result.age = old.age + 1
        result.allowedSide = old.allowedSide
        return result
    }

    private static func annotatedContacts(
        _ contacts: [ReferenceContact],
        endCenters: [ReferenceVector2],
        bubbles: [ReferenceBubble],
        segments: [ReferenceSegmentID: ReferenceSegment],
        indices: [ReferenceBubbleID: Int],
        configuration: ReferenceConfiguration
    ) -> [ReferenceContact] {
        contacts.compactMap { original in
            guard let indexA = indices[original.bubbleA] else { return nil }
            var contact = original
            let compression: Float
            if let idB = original.bubbleB, let indexB = indices[idB] {
                let delta = endCenters[indexB] - endCenters[indexA]
                let fallback = bubbles[indexA].id <= bubbles[indexB].id
                    ? ReferenceVector2(x: 1, y: 0) : ReferenceVector2(x: -1, y: 0)
                let normal = delta.normalized(or: fallback)
                compression = max(0, bubbles[indexA].targetRadius + bubbles[indexB].targetRadius
                    - delta.length)
                contact.compressionA = compression * 0.5
                contact.compressionB = compression * 0.5
                contact.normal = normal
                contact.pointQ = endCenters[indexA]
                    + normal * (bubbles[indexA].targetRadius - contact.compressionA)
                let distance = delta.length
                if distance > Float.ulpOfOne {
                    let radiusA = bubbles[indexA].targetRadius
                    let radiusB = bubbles[indexB].targetRadius
                    let planeDistance: Float
                    if distance >= abs(radiusA - radiusB) {
                        // For two intersecting natural circles this is their exact common chord.
                        planeDistance = (distance * distance + radiusA * radiusA - radiusB * radiusB)
                            / (2 * distance)
                    } else {
                        // One natural circle contains the other. There is no radical chord, so place
                        // a finite contact patch halfway between the two opposing radial surfaces.
                        planeDistance = (radiusA + distance - radiusB) * 0.5
                    }
                    let clampedPlaneDistance = min(radiusA, max(-radiusA, planeDistance))
                    contact.pointQ = endCenters[indexA] + normal * clampedPlaneDistance
                    let halfSpanA = max(
                        0, radiusA * radiusA - clampedPlaneDistance * clampedPlaneDistance
                    ).squareRoot()
                    let planeFromB = clampedPlaneDistance - distance
                    let halfSpanB = max(
                        0, radiusB * radiusB - planeFromB * planeFromB
                    ).squareRoot()
                    contact.contourHalfLength = min(halfSpanA, halfSpanB)
                } else {
                    contact.contourHalfLength = min(
                        bubbles[indexA].targetRadius, bubbles[indexB].targetRadius
                    )
                }
            } else if let segmentID = original.segment, let segment = segments[segmentID] {
                let closest = closestPoint(
                    to: endCenters[indexA], on: .init(a: segment.currentA, b: segment.currentB)
                )
                contact.pointQ = closest.point
                compression = max(0, bubbles[indexA].targetRadius - closest.distanceSquared.squareRoot())
                contact.compressionA = compression
                contact.compressionB = 0
                contact.contourHalfLength = nil
            } else {
                return nil
            }
            contact.penetration = compression
            contact.accumulatedCompression = compression
            let massB = original.bubbleB.flatMap { indices[$0] }.map { bubbles[$0].mass }
            let response = ReferenceContactResponse.coefficients(
                massA: bubbles[indexA].mass,
                massB: massB,
                stiffnessPerUnitMass: configuration.contactStiffness,
                dampingPerUnitMass: configuration.contactDamping
            )
            contact.pressure = response.stiffness * compression
            contact.effectiveStiffness = response.stiffness
            return contact
        }
    }

    private static func velocities(
        startCenters: [ReferenceVector2],
        startVelocities: [ReferenceVector2],
        endCenters: [ReferenceVector2],
        timeStep: Float
    ) -> [ReferenceVector2] {
        endCenters.indices.map {
            (endCenters[$0] - startCenters[$0]) * (2 / timeStep) - startVelocities[$0]
        }
    }

    private static func validTimeStep(_ candidate: Float, fallback: Float) -> Float {
        candidate.isFinite && candidate > 0 ? candidate : fallback
    }

    private static func vectorNorm(_ values: [ReferenceVector2]) -> Float {
        values.reduce(0) { $0 + $1.lengthSquared }.squareRoot()
    }
}
