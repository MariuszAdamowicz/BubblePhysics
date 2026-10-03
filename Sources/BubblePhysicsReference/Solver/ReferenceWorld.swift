import Foundation
import Dispatch

public struct ReferenceWorld {
    public let configuration: ReferenceConfiguration
    public private(set) var bubbles: [ReferenceBubble] = []
    public private(set) var segments: [ReferenceSegment] = []
    public private(set) var contacts = ReferenceContactSet()

    private var broadPhase: any ReferenceBroadPhase

    public init(configuration: ReferenceConfiguration, broadPhase: any ReferenceBroadPhase) {
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

    public mutating func updateBubble(_ bubble: ReferenceBubble) { addBubble(bubble) }

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
        let dt = configuration.timeStep
        for index in bubbles.indices {
            bubbles[index].previousCenter = bubbles[index].center
        }

        var elapsed: Float = 0
        var remaining = dt
        var eventGroups = 0
        var solverSubsteps = 0
        var didReachEventLimit = false
        var candidatePairCount = 0
        var generatedContactCount = 0
        var toiTests = 0
        var ccdExhaustions = 0
        var combinedSolver = emptySolverReport()
        var hasSolverReport = false
        let epsilon = max(configuration.positionTolerance, 1e-7)

        while remaining > epsilon {
            let intervalStartBubbles = bubbles
            let intervalStartContacts = contacts
            let tentativeSegments = segmentsForInterval(
                startTime: elapsed, duration: remaining, frameDuration: dt
            )
            let tentativeReport = ReferenceEquilibriumSolver.solve(
                bubbles: &bubbles,
                segments: tentativeSegments,
                contacts: &contacts,
                configuration: configuration,
                timeStep: remaining
            )
            let tentativeEndBubbles = bubbles
            let scan = scanEvents(
                startBubbles: intervalStartBubbles,
                endBubbles: tentativeEndBubbles,
                activeContacts: intervalStartContacts,
                elapsed: elapsed,
                duration: remaining
            )
            candidatePairCount += scan.candidatePairCount
            toiTests += scan.toiTestCount
            ccdExhaustions += scan.ccdBudgetExhaustionCount
            guard let firstGroup = scan.groups.first else {
                merge(tentativeReport, into: &combinedSolver, hasExisting: hasSolverReport)
                hasSolverReport = true
                solverSubsteps += 1
                elapsed += remaining
                remaining = 0
                break
            }

            bubbles = intervalStartBubbles
            contacts = intervalStartContacts
            let interval = firstGroup.time
            if interval > epsilon {
                let intervalSegments = segmentsForInterval(
                    startTime: elapsed, duration: interval, frameDuration: dt
                )
                let report = ReferenceEquilibriumSolver.solve(
                    bubbles: &bubbles,
                    segments: intervalSegments,
                    contacts: &contacts,
                    configuration: configuration,
                    timeStep: interval
                )
                merge(report, into: &combinedSolver, hasExisting: hasSolverReport)
                hasSolverReport = true
                solverSubsteps += 1
                elapsed += interval
                remaining = max(0, remaining - interval)
            }

            activate(firstGroup.events, candidates: scan.candidates)
            generatedContactCount += firstGroup.events.count
            eventGroups += 1

            if scan.didReachLimit || eventGroups >= configuration.maximumEventGroups {
                didReachEventLimit = scan.didReachLimit || remaining > epsilon
                let remainingEvents = scan.groups.dropFirst().flatMap(\.events)
                activate(remainingEvents, candidates: scan.candidates)
                generatedContactCount += remainingEvents.count
                if remaining > epsilon {
                    let intervalSegments = segmentsForInterval(
                        startTime: elapsed, duration: remaining, frameDuration: dt
                    )
                    let report = ReferenceEquilibriumSolver.solve(
                        bubbles: &bubbles,
                        segments: intervalSegments,
                        contacts: &contacts,
                        configuration: configuration,
                        timeStep: remaining
                    )
                    merge(report, into: &combinedSolver, hasExisting: hasSolverReport)
                    hasSolverReport = true
                    solverSubsteps += 1
                    elapsed += remaining
                    remaining = 0
                }
                break
            }

            if interval <= epsilon, remaining <= epsilon { break }
        }

        if !hasSolverReport {
            combinedSolver = emptySolverReport()
        }
        let centerGuardCount = applyCenterGuards()
        applyBoundedFriction(timeStep: dt)
        let angularFactor = expf(-configuration.angularDamping * dt)
        for index in bubbles.indices {
            bubbles[index].rotation += bubbles[index].angularVelocity * dt
            bubbles[index].angularVelocity *= angularFactor
        }

        let totalEnd = DispatchTime.now().uptimeNanoseconds
        return ReferenceWorldStepReport(
            solver: combinedSolver,
            candidatePairCount: candidatePairCount,
            generatedContactCount: generatedContactCount,
            persistentContactCount: contacts.contacts.count,
            toiTestCount: toiTests,
            sideCorrectionCount: centerGuardCount,
            ccdBudgetExhaustionCount: ccdExhaustions,
            centerGuardCount: centerGuardCount,
            eventGroupCount: eventGroups,
            solverSubstepCount: solverSubsteps,
            didReachEventGroupLimit: didReachEventLimit,
            predictionMilliseconds: 0,
            broadPhaseMilliseconds: 0,
            contactMilliseconds: 0,
            solverMilliseconds: milliseconds(totalEnd - totalStart),
            totalMilliseconds: milliseconds(totalEnd - totalStart),
            hasNonFiniteState: combinedSolver.hasNonFiniteState || bubbles.contains {
                !$0.center.isFinite || !$0.velocity.isFinite
                    || !$0.rotation.isFinite || !$0.angularVelocity.isFinite
            }
        )
    }

    public func contour(for id: ReferenceBubbleID) -> [ReferenceVector2] {
        guard let bubble = bubbles.first(where: { $0.id == id }) else { return [] }
        return ReferenceContourGenerator.points(for: bubble, configuration: configuration)
    }

    private struct EventScan {
        var groups: [ReferenceContactEventGroup]
        var didReachLimit: Bool
        var candidates: [ReferenceContactID: ReferenceContact]
        var candidatePairCount: Int
        var toiTestCount: Int
        var ccdBudgetExhaustionCount: Int
    }

    private mutating func scanEvents(
        startBubbles: [ReferenceBubble],
        endBubbles: [ReferenceBubble],
        activeContacts: ReferenceContactSet,
        elapsed: Float,
        duration: Float
    ) -> EventScan {
        let proxies = zip(startBubbles, endBubbles).map { start, end in
            ReferenceProxy(id: proxyID(for: start.id), bounds: sweptBounds(from: start.center, to: end.center, radius: start.targetRadius))
        }
        let pairs = broadPhase.candidatePairs(for: proxies)
        let indices = Dictionary(uniqueKeysWithValues: startBubbles.indices.map { (startBubbles[$0].id, $0) })
        let activeIDs = Set(activeContacts.contacts.map(\.id))
        var events: [ReferenceContactEvent] = []
        var candidates: [ReferenceContactID: ReferenceContact] = [:]
        var tests = 0
        var exhausted = 0

        for pair in pairs {
            guard let idA = bubbleID(for: pair.first), let idB = bubbleID(for: pair.second),
                  let indexA = indices[idA], let indexB = indices[idB] else { continue }
            let candidate = ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(startBubbles[indexA], startBubbles[indexB])
            guard !activeIDs.contains(candidate.id) else { continue }
            tests += 1
            var pathA = startBubbles[indexA]
            var pathB = startBubbles[indexB]
            pathA.previousCenter = startBubbles[indexA].center
            pathA.center = endBubbles[indexA].center
            pathA.directionalDeformations.removeAll(keepingCapacity: true)
            pathB.previousCenter = startBubbles[indexB].center
            pathB.center = endBubbles[indexB].center
            pathB.directionalDeformations.removeAll(keepingCapacity: true)
            switch ReferenceCCD.bubbleBubble(pathA, pathB) {
            case let .impact(fraction, _, _):
                let event = ReferenceContactEvent(time: duration * fraction, contactID: candidate.id)
                events.append(event)
                candidates[candidate.id] = contactAtFraction(
                    indexA: indexA, indexB: indexB, fraction: fraction,
                    startBubbles: startBubbles, endBubbles: endBubbles
                )
            case .initialOverlap:
                events.append(.init(time: 0, contactID: candidate.id))
                candidates[candidate.id] = candidate
            case .none:
                break
            }
        }

        let intervalSegments = segmentsForInterval(
            startTime: elapsed, duration: duration, frameDuration: configuration.timeStep
        )
        for segment in intervalSegments {
            for index in startBubbles.indices {
                let candidate = ReferenceDiscreteContactGenerator.bubbleSegmentCandidate(startBubbles[index], segment)
                guard !activeIDs.contains(candidate.id) else { continue }
                tests += 1
                var path = startBubbles[index]
                path.previousCenter = startBubbles[index].center
                path.center = endBubbles[index].center
                path.directionalDeformations.removeAll(keepingCapacity: true)
                let result = ReferenceCCD.bubbleSegment(path, segment, configuration: configuration)
                if result.didExhaustBudget { exhausted += 1 }
                switch result.timeOfImpact {
                case let .impact(fraction, normal, point):
                    var impact = candidate
                    impact.normal = normal
                    impact.pointQ = point
                    impact.penetration = 0
                    events.append(.init(time: duration * fraction, contactID: candidate.id))
                    candidates[candidate.id] = impact
                case .initialOverlap:
                    events.append(.init(time: 0, contactID: candidate.id))
                    candidates[candidate.id] = candidate
                case .none:
                    break
                }
            }
        }

        let queue = ReferenceContactEventQueue.groups(
            events: events,
            frameDuration: duration,
            simultaneousTolerance: configuration.simultaneousEventTolerance,
            limit: max(1, configuration.maximumEventGroups - 0)
        )
        return .init(
            groups: queue.groups,
            didReachLimit: queue.didReachLimit,
            candidates: candidates,
            candidatePairCount: pairs.count,
            toiTestCount: tests,
            ccdBudgetExhaustionCount: exhausted
        )
    }

    private func contactAtFraction(
        indexA: Int,
        indexB: Int,
        fraction: Float,
        startBubbles: [ReferenceBubble],
        endBubbles: [ReferenceBubble]
    ) -> ReferenceContact {
        var a = startBubbles[indexA]
        var b = startBubbles[indexB]
        a.center = a.center + (endBubbles[indexA].center - a.center) * fraction
        b.center = b.center + (endBubbles[indexB].center - b.center) * fraction
        return ReferenceDiscreteContactGenerator.bubbleBubbleCandidate(a, b)
    }

    private mutating func activate(
        _ events: [ReferenceContactEvent],
        candidates: [ReferenceContactID: ReferenceContact]
    ) {
        var byID = Dictionary(uniqueKeysWithValues: contacts.contacts.map { ($0.id, $0) })
        for event in events where byID[event.contactID] == nil {
            if let candidate = candidates[event.contactID] { byID[event.contactID] = candidate }
        }
        contacts = ReferenceContactSet(contacts: byID.values.sorted { $0.id < $1.id })
    }

    private func segmentsForInterval(
        startTime: Float,
        duration: Float,
        frameDuration: Float
    ) -> [ReferenceSegment] {
        let startFraction = min(1, max(0, startTime / frameDuration))
        let endFraction = min(1, max(0, (startTime + duration) / frameDuration))
        return segments.map { segment in
            let startA = segment.previousA + (segment.currentA - segment.previousA) * startFraction
            let startB = segment.previousB + (segment.currentB - segment.previousB) * startFraction
            let endA = segment.previousA + (segment.currentA - segment.previousA) * endFraction
            let endB = segment.previousB + (segment.currentB - segment.previousB) * endFraction
            if segment.motion == .staticBody {
                return .staticSegment(
                    id: segment.id, a: endA, b: endB,
                    ownerID: segment.ownerID, collisionMode: segment.collisionMode
                )
            }
            return .kinematicSegment(
                id: segment.id,
                previousA: startA, previousB: startB,
                currentA: endA, currentB: endB,
                timeStep: max(duration, Float.ulpOfOne),
                angularVelocity: segment.angularVelocity,
                ownerID: segment.ownerID,
                collisionMode: segment.collisionMode
            )
        }
    }

    private mutating func applyCenterGuards() -> Int {
        var count = 0
        for bubbleIndex in bubbles.indices {
            for segment in segments {
                let result = ReferenceCenterSegmentTOI.firstIntersection(
                    bubble: bubbles[bubbleIndex], segment: segment,
                    tolerance: configuration.positionTolerance
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
                    let margin = max(configuration.contactTolerance * 2, configuration.positionTolerance)
                    if currentSide * desiredSign < margin {
                        bubbles[bubbleIndex].center = bubbles[bubbleIndex].center
                            + currentNormal * (desiredSign * margin - currentSide)
                    }
                    count += 1
                }
                guard let sign = segment.collisionMode.allowedSide else { continue }
                let edge = segment.currentB - segment.currentA
                let normal = ReferenceVector2(x: -edge.y, y: edge.x)
                    .normalized(or: .init(x: 0, y: 1)) * sign
                let signed = (bubbles[bubbleIndex].center - segment.currentA).dot(normal)
                if signed < 0 {
                    bubbles[bubbleIndex].center = bubbles[bubbleIndex].center - normal * signed
                    count += 1
                }
            }
        }
        return count
    }

    private mutating func applyBoundedFriction(timeStep: Float) {
        let segmentMap = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        let indices = Dictionary(uniqueKeysWithValues: bubbles.indices.map { (bubbles[$0].id, $0) })
        for contact in contacts.contacts where contact.kind == .bubbleSegment && contact.pressure > 0 {
            guard let index = indices[contact.bubbleA], let segmentID = contact.segment,
                  let segment = segmentMap[segmentID], segment.motion == .kinematic else { continue }
            let tangent = ReferenceVector2(x: contact.normal.y, y: -contact.normal.x)
                .normalized(or: .init(x: 1, y: 0))
            let relativeSpeed = (segment.linearVelocity - bubbles[index].velocity).dot(tangent)
            let limit = configuration.surfaceFriction * contact.pressure * timeStep
            let impulse = min(limit, max(-limit, relativeSpeed * bubbles[index].mass))
            let impulseVector = tangent * impulse
            bubbles[index].velocity = bubbles[index].velocity + impulseVector * bubbles[index].inverseMass
            let lever = contact.pointQ - bubbles[index].center
            let inertia = max(0.5 * bubbles[index].mass * bubbles[index].targetRadius * bubbles[index].targetRadius,
                              Float.ulpOfOne)
            bubbles[index].angularVelocity += lever.cross(impulseVector) / inertia
        }
    }

    private func emptySolverReport() -> ReferenceSolverReport {
        .init(
            iterations: 0, maximumPenetration: 0, converged: true,
            didReachIterationLimit: false, positionCorrectionCount: 0,
            deformationCount: 0
        )
    }

    private func merge(
        _ report: ReferenceSolverReport,
        into aggregate: inout ReferenceSolverReport,
        hasExisting: Bool
    ) {
        if !hasExisting {
            aggregate = report
            return
        }
        aggregate.iterations += report.iterations
        aggregate.maximumPenetration = max(aggregate.maximumPenetration, report.maximumPenetration)
        aggregate.converged = aggregate.converged && report.converged
        aggregate.didReachIterationLimit = aggregate.didReachIterationLimit || report.didReachIterationLimit
        aggregate.positionCorrectionCount += report.positionCorrectionCount
        aggregate.deformationCount += report.deformationCount
        aggregate.pcgIterationCount += report.pcgIterationCount
        aggregate.finalResidualNorm = report.finalResidualNorm
        aggregate.maximumRelativeDeformation = max(
            aggregate.maximumRelativeDeformation, report.maximumRelativeDeformation
        )
        aggregate.lineSearchFailureCount += report.lineSearchFailureCount
        aggregate.hasNonFiniteState = aggregate.hasNonFiniteState || report.hasNonFiniteState
    }

    private func sweptBounds(
        from start: ReferenceVector2,
        to end: ReferenceVector2,
        radius: Float
    ) -> ReferenceAABB {
        .init(
            minimum: .init(x: min(start.x, end.x) - radius, y: min(start.y, end.y) - radius),
            maximum: .init(x: max(start.x, end.x) + radius, y: max(start.y, end.y) + radius)
        )
    }

    private func proxyID(for bubbleID: ReferenceBubbleID) -> ReferenceProxyID {
        .init(rawValue: bubbleID.rawValue)
    }

    private func bubbleID(for proxyID: ReferenceProxyID) -> ReferenceBubbleID? {
        let id = ReferenceBubbleID(rawValue: proxyID.rawValue)
        return bubbles.contains(where: { $0.id == id }) ? id : nil
    }

    private func milliseconds(_ nanoseconds: UInt64) -> Double {
        Double(nanoseconds) / 1_000_000
    }
}
