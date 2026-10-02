public extension ReferenceCCD {
    static func bubbleBubble(
        _ bubbleA: ReferenceBubble,
        _ bubbleB: ReferenceBubble
    ) -> TimeOfImpactResult {
        let initialDelta = bubbleB.previousCenter - bubbleA.previousCenter
        let fallback = bubbleA.id <= bubbleB.id
            ? ReferenceVector2(x: 1, y: 0)
            : ReferenceVector2(x: -1, y: 0)
        let initialNormal = initialDelta.normalized(or: fallback)
        let radiusA = bubbleA.supportRadius(along: initialNormal)
        let radiusB = bubbleB.supportRadius(along: -initialNormal)
        let combinedRadius = radiusA + radiusB

        if initialDelta.lengthSquared <= combinedRadius * combinedRadius {
            return .initialOverlap(
                normal: initialNormal,
                point: bubbleA.previousCenter + initialNormal * radiusA
            )
        }

        let movementA = bubbleA.center - bubbleA.previousCenter
        let movementB = bubbleB.center - bubbleB.previousCenter
        let relativeMovement = movementB - movementA
        let quadraticA = relativeMovement.lengthSquared
        guard quadraticA > Float.ulpOfOne else { return .none }

        let quadraticB = 2 * initialDelta.dot(relativeMovement)
        let quadraticC = initialDelta.lengthSquared - combinedRadius * combinedRadius
        let discriminant = quadraticB * quadraticB - 4 * quadraticA * quadraticC
        guard discriminant >= 0 else { return .none }

        let fraction = (-quadraticB - discriminant.squareRoot()) / (2 * quadraticA)
        guard fraction >= 0, fraction <= 1 else { return .none }

        let centerA = bubbleA.previousCenter + movementA * fraction
        let centerB = bubbleB.previousCenter + movementB * fraction
        let normal = (centerB - centerA).normalized(or: fallback)
        return .impact(
            fraction: fraction,
            normal: normal,
            point: centerA + normal * radiusA
        )
    }
}
