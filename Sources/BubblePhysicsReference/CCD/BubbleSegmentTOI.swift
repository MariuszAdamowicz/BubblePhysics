public struct ReferenceSegmentTOIResult: Sendable, Equatable, CustomStringConvertible {
    public var timeOfImpact: TimeOfImpactResult
    public var didExhaustBudget: Bool
    public var requiresSideCorrection: Bool

    public init(
        timeOfImpact: TimeOfImpactResult,
        didExhaustBudget: Bool = false,
        requiresSideCorrection: Bool = false
    ) {
        self.timeOfImpact = timeOfImpact
        self.didExhaustBudget = didExhaustBudget
        self.requiresSideCorrection = requiresSideCorrection
    }

    public var description: String {
        "ReferenceSegmentTOIResult(timeOfImpact: \(timeOfImpact), didExhaustBudget: \(didExhaustBudget), requiresSideCorrection: \(requiresSideCorrection))"
    }
}

public extension ReferenceCCD {
    static func bubbleSegment(
        _ bubble: ReferenceBubble,
        _ segment: ReferenceSegment,
        allowedSide: Float,
        configuration: ReferenceConfiguration
    ) -> ReferenceSegmentTOIResult {
        let bubbleMovement = bubble.center - bubble.previousCenter
        let movementA = segment.currentA - segment.previousA
        let movementB = segment.currentB - segment.previousB
        let isTranslation = (movementA - movementB).lengthSquared <= 1e-10

        if isTranslation {
            return translatedSegmentTOI(
                bubble: bubble,
                segment: segment,
                segmentMovement: movementA,
                allowedSide: allowedSide
            )
        }

        return conservativeSegmentTOI(
            bubble: bubble,
            segment: segment,
            allowedSide: allowedSide,
            configuration: configuration,
            bubbleMovement: bubbleMovement,
            movementA: movementA,
            movementB: movementB
        )
    }

    private static func translatedSegmentTOI(
        bubble: ReferenceBubble,
        segment: ReferenceSegment,
        segmentMovement: ReferenceVector2,
        allowedSide: Float
    ) -> ReferenceSegmentTOIResult {
        let endpoints = ReferenceSegmentEndpoints(a: segment.previousA, b: segment.previousB)
        let start = bubble.previousCenter
        let movement = (bubble.center - bubble.previousCenter) - segmentMovement
        let initialClosest = closestPoint(to: start, on: endpoints)
        let initialNormal = (start - initialClosest.point).normalized(
            or: allowedNormal(for: endpoints, allowedSide: allowedSide)
        )
        let radius = bubble.supportRadius(along: -initialNormal)

        if initialClosest.distanceSquared <= radius * radius {
            return .init(timeOfImpact: .initialOverlap(normal: initialNormal, point: initialClosest.point))
        }

        var bestFraction: Float?
        var bestNormal = initialNormal
        var bestPoint = initialClosest.point

        for endpoint in [endpoints.a, endpoints.b] {
            if let fraction = rayCircleFraction(origin: start, movement: movement, center: endpoint, radius: radius),
               fraction < (bestFraction ?? .infinity) {
                let centerAtImpact = start + movement * fraction
                bestFraction = fraction
                bestNormal = (centerAtImpact - endpoint).normalized(or: initialNormal)
                bestPoint = endpoint
            }
        }

        let edge = endpoints.b - endpoints.a
        let edgeLengthSquared = edge.lengthSquared
        if edgeLengthSquared > Float.ulpOfOne {
            let lineNormal = ReferenceVector2(x: -edge.y, y: edge.x).normalized(or: initialNormal)
            let initialDistance = (start - endpoints.a).dot(lineNormal)
            let distanceMovement = movement.dot(lineNormal)
            if abs(distanceMovement) > Float.ulpOfOne {
                for signedRadius in [radius, -radius] {
                    let fraction = (signedRadius - initialDistance) / distanceMovement
                    guard fraction >= 0, fraction <= 1, fraction < (bestFraction ?? .infinity) else { continue }
                    let centerAtImpact = start + movement * fraction
                    let projection = (centerAtImpact - endpoints.a).dot(edge) / edgeLengthSquared
                    guard projection >= 0, projection <= 1 else { continue }
                    bestFraction = fraction
                    bestNormal = lineNormal * (signedRadius < 0 ? -1 : 1)
                    bestPoint = endpoints.a + edge * projection
                }
            }
        }

        if let fraction = bestFraction {
            let worldPoint = bestPoint + segmentMovement * fraction
            return .init(timeOfImpact: .impact(fraction: fraction, normal: bestNormal, point: worldPoint))
        }

        return .init(
            timeOfImpact: .none,
            requiresSideCorrection: changedSide(bubble: bubble, segment: segment, allowedSide: allowedSide)
        )
    }

    private static func conservativeSegmentTOI(
        bubble: ReferenceBubble,
        segment: ReferenceSegment,
        allowedSide: Float,
        configuration: ReferenceConfiguration,
        bubbleMovement: ReferenceVector2,
        movementA: ReferenceVector2,
        movementB: ReferenceVector2
    ) -> ReferenceSegmentTOIResult {
        let speedBound = bubbleMovement.length + max(movementA.length, movementB.length)
        var fraction: Float = 0

        for iteration in 0..<configuration.toiIterationBudget {
            let center = bubble.previousCenter + bubbleMovement * fraction
            let a = segment.previousA + movementA * fraction
            let b = segment.previousB + movementB * fraction
            let endpoints = ReferenceSegmentEndpoints(a: a, b: b)
            let closest = closestPoint(to: center, on: endpoints)
            let normal = (center - closest.point).normalized(
                or: allowedNormal(for: endpoints, allowedSide: allowedSide)
            )
            let radius = bubble.supportRadius(along: -normal)
            let distance = closest.distanceSquared.squareRoot()

            if distance <= radius + configuration.contactTolerance {
                let impact: TimeOfImpactResult = fraction == 0
                    ? .initialOverlap(normal: normal, point: closest.point)
                    : .impact(fraction: fraction, normal: normal, point: closest.point)
                return .init(timeOfImpact: impact)
            }

            guard speedBound > Float.ulpOfOne else { return .init(timeOfImpact: .none) }
            let safeAdvance = max(configuration.positionTolerance, (distance - radius) / speedBound * 0.8)
            fraction += safeAdvance
            if fraction > 1 { return .init(timeOfImpact: .none) }

            if iteration == configuration.toiIterationBudget - 1 {
                return .init(
                    timeOfImpact: .none,
                    didExhaustBudget: true,
                    requiresSideCorrection: changedSide(bubble: bubble, segment: segment, allowedSide: allowedSide)
                )
            }
        }

        return .init(timeOfImpact: .none)
    }

    private static func rayCircleFraction(
        origin: ReferenceVector2,
        movement: ReferenceVector2,
        center: ReferenceVector2,
        radius: Float
    ) -> Float? {
        let relative = origin - center
        let a = movement.lengthSquared
        guard a > Float.ulpOfOne else { return nil }
        let b = 2 * relative.dot(movement)
        let c = relative.lengthSquared - radius * radius
        let discriminant = b * b - 4 * a * c
        guard discriminant >= 0 else { return nil }
        let fraction = (-b - discriminant.squareRoot()) / (2 * a)
        return fraction >= 0 && fraction <= 1 ? fraction : nil
    }

    private static func allowedNormal(
        for endpoints: ReferenceSegmentEndpoints,
        allowedSide: Float
    ) -> ReferenceVector2 {
        let edge = endpoints.b - endpoints.a
        let sign: Float = allowedSide < 0 ? -1 : 1
        return ReferenceVector2(x: -edge.y, y: edge.x)
            .normalized(or: ReferenceVector2(x: 0, y: 1)) * sign
    }

    private static func changedSide(
        bubble: ReferenceBubble,
        segment: ReferenceSegment,
        allowedSide: Float
    ) -> Bool {
        let sign: Float = allowedSide < 0 ? -1 : 1
        let previousEdge = segment.previousB - segment.previousA
        let currentEdge = segment.currentB - segment.currentA
        let previousSide = previousEdge.cross(bubble.previousCenter - segment.previousA) * sign
        let currentSide = currentEdge.cross(bubble.center - segment.currentA) * sign
        return previousSide >= 0 && currentSide < 0
    }
}
