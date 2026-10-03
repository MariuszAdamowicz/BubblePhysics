import Foundation
import Dispatch

public struct ReferenceWorld {
    public let configuration: ReferenceConfiguration
    public private(set) var bubbles: [ReferenceBubble] = []
    public private(set) var segments: [ReferenceSegment] = []
    public private(set) var contacts = ReferenceContactSet()

    private var broadPhase: any ReferenceBroadPhase

    public init(
        configuration: ReferenceConfiguration,
        broadPhase: any ReferenceBroadPhase
    ) {
        self.configuration = configuration.sanitized
        self.broadPhase = broadPhase
    }

    public mutating func addBubble(_ bubble: ReferenceBubble) {
        if let index = bubbles.firstIndex(where: { $0.id == bubble.id }) {
            bubbles[index] = bubble
        } else {
            bubbles.append(bubble)
            bubbles.sort { $0.id < $1.id }
        }
    }

    public mutating func updateBubble(_ bubble: ReferenceBubble) {
        addBubble(bubble)
    }

    public mutating func addSegment(_ segment: ReferenceSegment) {
        if let index = segments.firstIndex(where: { $0.id == segment.id }) {
            segments[index] = segment
        } else {
            segments.append(segment)
            segments.sort { $0.id < $1.id }
        }
    }

    public mutating func updateSegment(_ segment: ReferenceSegment) {
        guard let index = segments.firstIndex(where: { $0.id == segment.id }) else {
            addSegment(segment)
            return
        }
        segments[index] = segment
    }

    public mutating func removeSegment(id: ReferenceSegmentID) {
        segments.removeAll { $0.id == id }
    }

    public mutating func step() -> ReferenceWorldStepReport {
        let totalStart = DispatchTime.now().uptimeNanoseconds

        let predictionStart = DispatchTime.now().uptimeNanoseconds
        recoverDeformations()
        for index in bubbles.indices {
            bubbles[index].previousCenter = bubbles[index].center
            bubbles[index].center = bubbles[index].center
                + bubbles[index].velocity * configuration.timeStep
            bubbles[index].rotation += bubbles[index].angularVelocity * configuration.timeStep
        }
        let predictionEnd = DispatchTime.now().uptimeNanoseconds

        let broadStart = predictionEnd
        let proxies = bubbles.map { bubble in
            ReferenceProxy(id: proxyID(for: bubble.id), bounds: sweptBounds(for: bubble))
        }
        let pairs = broadPhase.candidatePairs(for: proxies)
        let broadEnd = DispatchTime.now().uptimeNanoseconds

        let contactStart = broadEnd
        let bubbleIndices = Dictionary(uniqueKeysWithValues: bubbles.indices.map { (bubbles[$0].id, $0) })
        var generatedContacts: [ReferenceContact] = []
        var toiTests = 0
        var sideCorrections = 0
        var ccdBudgetExhaustions = 0
        var generatedContactIDs: Set<ReferenceContactID> = []

        for pair in pairs {
            guard let idA = bubbleID(for: pair.first), let idB = bubbleID(for: pair.second),
                  let indexA = bubbleIndices[idA], let indexB = bubbleIndices[idB] else { continue }
            toiTests += 1
            applyBubbleTOI(indexA: indexA, indexB: indexB)
            let candidate = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(bubbles[indexA], bubbles[indexB])
            generatedContacts.append(candidate)
            generatedContactIDs.insert(candidate.id)
        }

        // Broad phase may drop a barely separated pair; signed candidates preserve hysteresis.
        for previous in contacts.contacts where previous.kind == .bubbleBubble && !generatedContactIDs.contains(previous.id) {
            guard let bubbleB = previous.bubbleB,
                  let indexA = bubbleIndices[previous.bubbleA],
                  let indexB = bubbleIndices[bubbleB] else { continue }
            generatedContacts.append(ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(
                bubbles[indexA], bubbles[indexB]
            ))
        }

        for segment in segments {
            for index in bubbles.indices {
                toiTests += 1
                let result = ReferenceCCD.bubbleSegment(
                    bubbles[index], segment,
                    configuration: configuration
                )
                if result.didExhaustBudget { ccdBudgetExhaustions += 1 }
                generatedContacts.append(ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(
                    bubbles[index], segment
                ))
            }
        }
        contacts.update(
            candidates: generatedContacts,
            bubbles: bubbles,
            segments: segments,
            configuration: configuration
        )
        let generatedActiveContactCount = generatedContacts.reduce(into: 0) { count, candidate in
            if candidate.penetration > configuration.contactTolerance { count += 1 }
        }
        let contactEnd = DispatchTime.now().uptimeNanoseconds

        let solverStart = contactEnd
        let solverReport = ReferenceEquilibriumSolver.solve(
            bubbles: &bubbles,
            segments: segments,
            contacts: &contacts,
            configuration: configuration,
            candidatePairs: pairs
        )
        let centerGuardCount = applyCenterGuards()
        sideCorrections += centerGuardCount
        let linearFactor = expf(-configuration.linearDamping * configuration.timeStep)
        let angularFactor = expf(-configuration.angularDamping * configuration.timeStep)
        for index in bubbles.indices {
            let positionalVelocity = (bubbles[index].center - bubbles[index].previousCenter) / configuration.timeStep
            bubbles[index].velocity = positionalVelocity * linearFactor
            bubbles[index].angularVelocity *= angularFactor
        }
        applyBoundedFriction()
        let solverEnd = DispatchTime.now().uptimeNanoseconds

        return ReferenceWorldStepReport(
            solver: solverReport,
            candidatePairCount: pairs.count,
            generatedContactCount: generatedActiveContactCount,
            persistentContactCount: contacts.contacts.count,
            toiTestCount: toiTests,
            sideCorrectionCount: sideCorrections,
            ccdBudgetExhaustionCount: ccdBudgetExhaustions,
            centerGuardCount: centerGuardCount,
            predictionMilliseconds: milliseconds(predictionEnd - predictionStart),
            broadPhaseMilliseconds: milliseconds(broadEnd - broadStart),
            contactMilliseconds: milliseconds(contactEnd - contactStart),
            solverMilliseconds: milliseconds(solverEnd - solverStart),
            totalMilliseconds: milliseconds(solverEnd - totalStart),
            hasNonFiniteState: bubbles.contains { bubble in
                !bubble.center.isFinite || !bubble.velocity.isFinite
                    || !bubble.rotation.isFinite || !bubble.angularVelocity.isFinite
                    || bubble.directionalDeformations.contains { !$0.depth.isFinite || !$0.pressure.isFinite }
            }
        )
    }

    private mutating func applyCenterGuards() -> Int {
        var count = 0
        for bubbleIndex in bubbles.indices {
            for segment in segments {
                let result = ReferenceCenterSegmentTOI.firstIntersection(
                    bubble: bubbles[bubbleIndex], segment: segment, tolerance: configuration.positionTolerance
                )
                if case .impact = result {
                    let previousEdge = segment.previousB - segment.previousA
                    let currentEdge = segment.currentB - segment.currentA
                    let previousNormal = ReferenceVector2(x: -previousEdge.y, y: previousEdge.x)
                        .normalized(or: .init(x: 0, y: 1))
                    let currentNormal = ReferenceVector2(x: -currentEdge.y, y: currentEdge.x)
                        .normalized(or: previousNormal)
                    let previousSide = (bubbles[bubbleIndex].previousCenter - segment.previousA).dot(previousNormal)
                    let desiredSign: Float = previousSide < 0 ? -1 : 1
                    let currentSide = (bubbles[bubbleIndex].center - segment.currentA).dot(currentNormal)
                    let guardMargin = max(configuration.contactTolerance * 2, configuration.positionTolerance)
                    let targetSide = desiredSign * guardMargin
                    if currentSide * desiredSign < guardMargin {
                        bubbles[bubbleIndex].center = bubbles[bubbleIndex].center
                            + currentNormal * (targetSide - currentSide)
                    }
                    count += 1
                }
                guard let sign = segment.collisionMode.allowedSide else { continue }
                let edge = segment.currentB - segment.currentA
                let allowedNormal = ReferenceVector2(x: -edge.y, y: edge.x)
                    .normalized(or: .init(x: 0, y: 1)) * sign
                let signed = (bubbles[bubbleIndex].center - segment.currentA).dot(allowedNormal)
                if signed < 0 {
                    bubbles[bubbleIndex].center = bubbles[bubbleIndex].center - allowedNormal * signed
                    count += 1
                }
            }
        }
        return count
    }

    private mutating func applyBoundedFriction() {
        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let bubbleIndices = Dictionary(uniqueKeysWithValues: bubbles.indices.map { (bubbles[$0].id, $0) })
        for contact in contacts.contacts where contact.kind == .bubbleSegment && contact.pressure > 0 {
            guard let index = bubbleIndices[contact.bubbleA], let segmentID = contact.segment,
                  let segment = segmentMap[segmentID], segment.motion == .kinematic else { continue }
            let tangent = ReferenceVector2(x: contact.normal.y, y: -contact.normal.x)
                .normalized(or: .init(x: 1, y: 0))
            let relativeSpeed = (segment.linearVelocity - bubbles[index].velocity).dot(tangent)
            let desiredImpulse = relativeSpeed * bubbles[index].mass
            let limit = configuration.surfaceFriction * contact.pressure * configuration.timeStep
            let impulse = min(limit, max(-limit, desiredImpulse))
            let impulseVector = tangent * impulse
            bubbles[index].velocity = bubbles[index].velocity + impulseVector * bubbles[index].inverseMass
            let lever = contact.pointQ - bubbles[index].center
            let inertia = max(0.5 * bubbles[index].mass * bubbles[index].targetRadius * bubbles[index].targetRadius,
                              Float.ulpOfOne)
            bubbles[index].angularVelocity += lever.cross(impulseVector) / inertia
        }
    }

    private mutating func recoverDeformations() {
        let factor = expf(-configuration.deformationRecoveryRate * configuration.timeStep)
        for bubbleIndex in bubbles.indices {
            bubbles[bubbleIndex].directionalDeformations = bubbles[bubbleIndex].directionalDeformations
                .compactMap { deformation in
                    var recovered = deformation
                    recovered.depth *= factor
                    recovered.pressure *= factor
                    return recovered.depth > configuration.positionTolerance ? recovered : nil
                }
        }
    }

    public func contour(for id: ReferenceBubbleID) -> [ReferenceVector2] {
        guard let bubble = bubbles.first(where: { $0.id == id }) else { return [] }
        return ReferenceContourGenerator.points(for: bubble, configuration: configuration)
    }

    private mutating func applyBubbleTOI(indexA: Int, indexB: Int) {
        switch ReferenceCCD.bubbleBubble(bubbles[indexA], bubbles[indexB]) {
        case let .impact(fraction, normal, _):
            let movementA = bubbles[indexA].center - bubbles[indexA].previousCenter
            let movementB = bubbles[indexB].center - bubbles[indexB].previousCenter
            bubbles[indexA].center = bubbles[indexA].previousCenter + movementA * fraction
                - normal * configuration.contactTolerance
            bubbles[indexB].center = bubbles[indexB].previousCenter + movementB * fraction
                + normal * configuration.contactTolerance
        case .none, .initialOverlap:
            break
        }
    }

    private mutating func applySegmentTOI(
        _ result: ReferenceSegmentTOIResult,
        bubbleIndex: Int,
        segment: ReferenceSegment
    ) -> Bool {
        var corrected = false
        switch result.timeOfImpact {
        case let .impact(fraction, normal, _):
            let movement = bubbles[bubbleIndex].center - bubbles[bubbleIndex].previousCenter
            bubbles[bubbleIndex].center = bubbles[bubbleIndex].previousCenter + movement * fraction
                + normal * configuration.contactTolerance
        case .none, .initialOverlap:
            break
        }

        guard let sign = segment.collisionMode.allowedSide else { return corrected }
        let edge = segment.currentB - segment.currentA
        let normal = ReferenceVector2(x: -edge.y, y: edge.x)
            .normalized(or: ReferenceVector2(x: 0, y: 1)) * sign
        let signedSide = (bubbles[bubbleIndex].center - segment.currentA).dot(normal)
        if signedSide < 0 || result.requiresSideCorrection {
            let radius = bubbles[bubbleIndex].supportRadius(along: -normal)
            bubbles[bubbleIndex].center = bubbles[bubbleIndex].center
                + normal * (radius - signedSide + configuration.contactTolerance)
            corrected = true
        }
        return corrected
    }

    private func sweptBounds(for bubble: ReferenceBubble) -> ReferenceAABB {
        let radius = bubble.targetRadius
        let minimum = ReferenceVector2(
            x: min(bubble.previousCenter.x, bubble.center.x) - radius,
            y: min(bubble.previousCenter.y, bubble.center.y) - radius
        )
        let maximum = ReferenceVector2(
            x: max(bubble.previousCenter.x, bubble.center.x) + radius,
            y: max(bubble.previousCenter.y, bubble.center.y) + radius
        )
        return ReferenceAABB(minimum: minimum, maximum: maximum)
    }

    private func proxyID(for bubbleID: ReferenceBubbleID) -> ReferenceProxyID {
        ReferenceProxyID(rawValue: bubbleID.rawValue)
    }

    private func bubbleID(for proxyID: ReferenceProxyID) -> ReferenceBubbleID? {
        let id = ReferenceBubbleID(rawValue: proxyID.rawValue)
        return bubbles.contains(where: { $0.id == id }) ? id : nil
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}
