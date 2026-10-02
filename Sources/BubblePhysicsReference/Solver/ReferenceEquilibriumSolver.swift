import Foundation

public enum ReferenceEquilibriumSolver {
    public static func solve(
        bubbles: inout [ReferenceBubble],
        segments: [ReferenceSegment],
        contacts: inout ReferenceContactSet,
        configuration: ReferenceConfiguration,
        candidatePairs: [ReferencePair]? = nil,
        segmentAllowedSides: [ReferenceSegmentID: Float] = [:]
    ) -> ReferenceSolverReport {
        let configuration = configuration.sanitized
        let bubbleIndices = Dictionary(uniqueKeysWithValues: bubbles.indices.map { (bubbles[$0].id, $0) })
        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var orderedContacts = contacts.contacts.sorted { $0.id < $1.id }
        var correctedPositions = 0
        var deformationCount = 0
        var iterations = 0
        var transferredFriction: Set<ReferenceContactID> = []

        for iteration in 0..<max(1, configuration.solverIterations) {
            iterations = iteration + 1
            var largestCorrection: Float = 0

            // Rigid geometry is absolute: establish its constraint before resolving pairs.
            for contact in orderedContacts where contact.kind == .bubbleSegment {
                guard let index = bubbleIndices[contact.bubbleA],
                      let segmentID = contact.segment,
                      let segment = segmentsByID[segmentID] else { continue }
                let correction = projectOut(
                    bubble: &bubbles[index], segment: segment,
                    allowedSide: contact.allowedSide ?? 1,
                    tolerance: configuration.positionTolerance
                )
                if correction > 0 {
                    correctedPositions += 1
                    largestCorrection = max(largestCorrection, correction)
                    if segmentContactCount(for: contact.bubbleA, in: orderedContacts) > 1 {
                        deformationCount += storeRigidCompression(
                            bubbleIndex: index,
                            contact: contact,
                            blockedDistance: correction,
                            bubbles: &bubbles,
                            configuration: configuration
                        )
                    }
                }
                if transferredFriction.insert(contact.id).inserted {
                    transferTangentialMotion(
                        bubble: &bubbles[index], segment: segment,
                        contactPoint: contact.pointQ,
                        normal: contact.normal,
                        friction: configuration.surfaceFriction
                    )
                }
            }

            for contact in orderedContacts where contact.kind == .bubbleBubble {
                guard let indexA = bubbleIndices[contact.bubbleA],
                      let bubbleBID = contact.bubbleB,
                      let indexB = bubbleIndices[bubbleBID] else { continue }
                var bubbleA = bubbles[indexA]
                var bubbleB = bubbles[indexB]
                let correction = separatePair(
                    bubbleA: &bubbleA, bubbleB: &bubbleB,
                    tolerance: configuration.positionTolerance
                )
                bubbles[indexA] = bubbleA
                bubbles[indexB] = bubbleB
                if correction > 0 {
                    correctedPositions += 1
                    largestCorrection = max(largestCorrection, correction)
                }
            }

            // Pair correction may have attempted to push a centre through rigid geometry.
            for contact in orderedContacts where contact.kind == .bubbleSegment {
                guard let index = bubbleIndices[contact.bubbleA],
                      let segmentID = contact.segment,
                      let segment = segmentsByID[segmentID] else { continue }
                let correction = projectOut(
                    bubble: &bubbles[index], segment: segment,
                    allowedSide: contact.allowedSide ?? 1,
                    tolerance: configuration.positionTolerance
                )
                if correction > 0 {
                    correctedPositions += 1
                    largestCorrection = max(largestCorrection, correction)
                    deformationCount += storeBlockedCompression(
                        bubbleIndex: index,
                        blockedDistance: correction,
                        bubbles: &bubbles,
                        contacts: orderedContacts,
                        configuration: configuration
                    )
                    if segmentContactCount(for: contact.bubbleA, in: orderedContacts) > 1 {
                        deformationCount += storeRigidCompression(
                            bubbleIndex: index,
                            contact: contact,
                            blockedDistance: correction,
                            bubbles: &bubbles,
                            configuration: configuration
                        )
                    }
                }
            }

            let candidates = regeneratedCandidates(
                bubbles: bubbles,
                segments: segments,
                existingContacts: orderedContacts,
                candidatePairs: candidatePairs,
                bubbleIndices: bubbleIndices,
                segmentAllowedSides: segmentAllowedSides
            )
            contacts.update(
                candidates: candidates,
                bubbles: bubbles,
                segments: segments,
                configuration: configuration
            )
            let previousIDs = orderedContacts.map(\.id)
            orderedContacts = contacts.contacts
            let contactSetChanged = orderedContacts.map(\.id) != previousIDs
            if largestCorrection <= configuration.positionTolerance && !contactSetChanged { break }
        }

        let finalCandidates = regeneratedCandidates(
            bubbles: bubbles,
            segments: segments,
            existingContacts: orderedContacts,
            candidatePairs: candidatePairs,
            bubbleIndices: bubbleIndices,
            segmentAllowedSides: segmentAllowedSides
        )
        contacts.update(
            candidates: finalCandidates,
            bubbles: bubbles,
            segments: segments,
            configuration: configuration
        )
        let maximumPenetration = max(0, contacts.contacts.map(\.penetration).max() ?? 0)

        let converged = maximumPenetration <= configuration.positionTolerance
        return ReferenceSolverReport(
            iterations: iterations,
            maximumPenetration: maximumPenetration,
            converged: converged,
            didReachIterationLimit: !converged && iterations >= max(1, configuration.solverIterations),
            positionCorrectionCount: correctedPositions,
            deformationCount: deformationCount
        )
    }

    private static func separatePair(
        bubbleA: inout ReferenceBubble,
        bubbleB: inout ReferenceBubble,
        tolerance: Float
    ) -> Float {
        let delta = bubbleB.center - bubbleA.center
        let fallback = bubbleA.id <= bubbleB.id
            ? ReferenceVector2(x: 1, y: 0) : ReferenceVector2(x: -1, y: 0)
        let normal = delta.normalized(or: fallback)
        let penetration = bubbleA.supportRadius(along: normal)
            + bubbleB.supportRadius(along: -normal) - delta.length
        guard penetration > tolerance else { return 0 }
        let inverseMassSum = bubbleA.inverseMass + bubbleB.inverseMass
        guard inverseMassSum > Float.ulpOfOne else { return 0 }
        bubbleA.center = bubbleA.center - normal * (penetration * bubbleA.inverseMass / inverseMassSum)
        bubbleB.center = bubbleB.center + normal * (penetration * bubbleB.inverseMass / inverseMassSum)
        return penetration
    }

    private static func projectOut(
        bubble: inout ReferenceBubble,
        segment: ReferenceSegment,
        allowedSide: Float,
        tolerance: Float
    ) -> Float {
        let edge = segment.currentB - segment.currentA
        let sign: Float = allowedSide < 0 ? -1 : 1
        let allowedNormal = ReferenceVector2(x: -edge.y, y: edge.x)
            .normalized(or: ReferenceVector2(x: 0, y: 1)) * sign
        let closest = closestPoint(
            to: bubble.center,
            on: ReferenceSegmentEndpoints(a: segment.currentA, b: segment.currentB)
        )
        var normal = (bubble.center - closest.point).normalized(or: allowedNormal)
        if normal.dot(allowedNormal) < 0 { normal = allowedNormal }
        let radius = bubble.supportRadius(along: -normal)
        let signedDistance = (bubble.center - closest.point).dot(normal)
        let penetration = radius - signedDistance
        guard penetration > tolerance else { return 0 }
        bubble.center = bubble.center + normal * penetration
        return penetration
    }

    private static func storeBlockedCompression(
        bubbleIndex: Int,
        blockedDistance: Float,
        bubbles: inout [ReferenceBubble],
        contacts: [ReferenceContact],
        configuration: ReferenceConfiguration
    ) -> Int {
        guard let pair = contacts.first(where: {
            $0.kind == .bubbleBubble && ($0.bubbleA == bubbles[bubbleIndex].id || $0.bubbleB == bubbles[bubbleIndex].id)
        }) else { return 0 }

        let direction = pair.bubbleA == bubbles[bubbleIndex].id ? pair.normal : -pair.normal
        let ratio = blockedDistance / max(bubbles[bubbleIndex].targetRadius, Float.ulpOfOne)
        let nonlinearResistance = 1 + configuration.nonlinearStiffening * ratio * ratio
        let depth = blockedDistance / nonlinearResistance
        guard depth > configuration.positionTolerance else { return 0 }
        let deformation = DirectionalDeformation(
            contactID: pair.id,
            direction: direction,
            depth: depth,
            angularWidth: .pi / 3,
            pressure: blockedDistance * bubbles[bubbleIndex].stiffness
        )
        if let existing = bubbles[bubbleIndex].directionalDeformations.firstIndex(where: { $0.contactID == pair.id }) {
            if deformation.depth > bubbles[bubbleIndex].directionalDeformations[existing].depth {
                bubbles[bubbleIndex].directionalDeformations[existing] = deformation
            }
        } else {
            bubbles[bubbleIndex].directionalDeformations.append(deformation)
        }
        return 1
    }

    private static func segmentContactCount(
        for bubbleID: ReferenceBubbleID,
        in contacts: [ReferenceContact]
    ) -> Int {
        contacts.reduce(into: 0) { count, contact in
            if contact.kind == .bubbleSegment && contact.bubbleA == bubbleID { count += 1 }
        }
    }

    private static func storeRigidCompression(
        bubbleIndex: Int,
        contact: ReferenceContact,
        blockedDistance: Float,
        bubbles: inout [ReferenceBubble],
        configuration: ReferenceConfiguration
    ) -> Int {
        let ratio = blockedDistance / max(bubbles[bubbleIndex].targetRadius, Float.ulpOfOne)
        let resistance = 1 + configuration.nonlinearStiffening * ratio * ratio
        let deformation = DirectionalDeformation(
            contactID: contact.id,
            direction: -contact.normal,
            depth: blockedDistance / resistance,
            angularWidth: .pi / 3,
            pressure: blockedDistance * bubbles[bubbleIndex].stiffness
        )
        guard deformation.depth > configuration.positionTolerance else { return 0 }
        if let existing = bubbles[bubbleIndex].directionalDeformations.firstIndex(where: {
            $0.contactID == contact.id
        }) {
            if deformation.depth > bubbles[bubbleIndex].directionalDeformations[existing].depth {
                bubbles[bubbleIndex].directionalDeformations[existing] = deformation
            }
        } else {
            bubbles[bubbleIndex].directionalDeformations.append(deformation)
        }
        return 1
    }

    private static func transferTangentialMotion(
        bubble: inout ReferenceBubble,
        segment: ReferenceSegment,
        contactPoint: ReferenceVector2,
        normal: ReferenceVector2,
        friction: Float
    ) {
        guard segment.motion == .kinematic, friction > 0 else { return }
        let tangent = ReferenceVector2(x: normal.y, y: -normal.x)
            .normalized(or: ReferenceVector2(x: 1, y: 0))
        let relativeSpeed = (segment.linearVelocity - bubble.velocity).dot(tangent)
        let tangentialChange = relativeSpeed * min(1, max(0, friction))
        let velocityChange = tangent * tangentialChange
        bubble.velocity = bubble.velocity + velocityChange
        let lever = contactPoint - bubble.center
        let inertiaScale = max(bubble.targetRadius * bubble.targetRadius, Float.ulpOfOne)
        bubble.angularVelocity += lever.cross(velocityChange) / inertiaScale
    }

    private static func regeneratedCandidates(
        bubbles: [ReferenceBubble],
        segments: [ReferenceSegment],
        existingContacts: [ReferenceContact],
        candidatePairs: [ReferencePair]?,
        bubbleIndices: [ReferenceBubbleID: Int],
        segmentAllowedSides: [ReferenceSegmentID: Float]
    ) -> [ReferenceContact] {
        var generated: [ReferenceContact] = []
        var pairIDs: Set<ReferencePair> = []

        if let candidatePairs { pairIDs.formUnion(candidatePairs) }
        for contact in existingContacts where contact.kind == .bubbleBubble {
            guard let bubbleB = contact.bubbleB else { continue }
            pairIDs.insert(ReferencePair(
                .init(rawValue: contact.bubbleA.rawValue),
                .init(rawValue: bubbleB.rawValue)
            ))
        }
        for pair in pairIDs.sorted() {
            let idA = ReferenceBubbleID(rawValue: pair.first.rawValue)
            let idB = ReferenceBubbleID(rawValue: pair.second.rawValue)
            guard let indexA = bubbleIndices[idA], let indexB = bubbleIndices[idB] else { continue }
            generated.append(ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(
                bubbles[indexA], bubbles[indexB]
            ))
        }

        let segmentsByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        var segmentKeys: Set<ReferenceContactID> = []
        if candidatePairs != nil {
            for segment in segments {
                for bubble in bubbles {
                    let contact = ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(
                        bubble, segment, allowedSide: segmentAllowedSides[segment.id] ?? 1
                    )
                    generated.append(contact)
                    segmentKeys.insert(contact.id)
                }
            }
        }
        for previous in existingContacts where previous.kind == .bubbleSegment && !segmentKeys.contains(previous.id) {
            guard let segmentID = previous.segment,
                  let segment = segmentsByID[segmentID],
                  let index = bubbleIndices[previous.bubbleA] else { continue }
            generated.append(ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(
                bubbles[index], segment,
                allowedSide: segmentAllowedSides[segmentID] ?? previous.allowedSide ?? 1
            ))
        }
        return generated
    }

}
