public enum ReferenceDiscreteContactGenerator {
    public static func bubbleBubble(
        _ bubbleA: ReferenceBubble,
        _ bubbleB: ReferenceBubble
    ) -> ReferenceContact? {
        let candidate = bubbleBubbleCandidate(bubbleA, bubbleB)
        return candidate.penetration > 0 ? candidate : nil
    }

    public static func bubbleBubbleCandidate(
        _ bubbleA: ReferenceBubble,
        _ bubbleB: ReferenceBubble
    ) -> ReferenceContact {
        let delta = bubbleB.center - bubbleA.center
        let fallback = bubbleA.id <= bubbleB.id
            ? ReferenceVector2(x: 1, y: 0)
            : ReferenceVector2(x: -1, y: 0)
        let normal = delta.normalized(or: fallback)
        let distance = delta.length
        let radiusA = bubbleA.supportRadius(along: normal)
        let radiusB = bubbleB.supportRadius(along: -normal)
        let penetration = radiusA + radiusB - distance
        return ReferenceContact(
            id: bubblePairID(bubbleA.id, bubbleB.id),
            kind: .bubbleBubble,
            bubbleA: bubbleA.id,
            bubbleB: bubbleB.id,
            normal: normal,
            pointQ: bubbleA.center + normal * radiusA,
            penetration: penetration
        )
    }

    public static func bubbleSegment(
        _ bubble: ReferenceBubble,
        _ segment: ReferenceSegment
    ) -> ReferenceContact? {
        let candidate = bubbleSegmentCandidate(bubble, segment)
        return candidate.penetration > 0 ? candidate : nil
    }

    public static func bubbleSegmentCandidate(
        _ bubble: ReferenceBubble,
        _ segment: ReferenceSegment
    ) -> ReferenceContact {
        let endpoints = ReferenceSegmentEndpoints(a: segment.currentA, b: segment.currentB)
        let closest = closestPoint(to: bubble.center, on: endpoints)
        let edge = segment.currentB - segment.currentA
        let baseNormal = ReferenceVector2(x: -edge.y, y: edge.x)
            .normalized(or: ReferenceVector2(x: 0, y: 1))
        let allowedSide = segment.collisionMode.allowedSide
        let fallbackSign: Float = ((bubble.id.rawValue ^ segment.id.rawValue) & 1) == 0 ? 1 : -1
        let fallback = allowedSide.map { baseNormal * $0 } ?? baseNormal * fallbackSign
        let normal = allowedSide.map { _ in fallback }
            ?? (bubble.center - closest.point).normalized(or: fallback)
        let radius = bubble.supportRadius(along: -normal)
        let penetration = radius - closest.distanceSquared.squareRoot()
        return ReferenceContact(
            id: bubbleSegmentID(bubble.id, segment.id),
            kind: .bubbleSegment,
            bubbleA: bubble.id,
            segment: segment.id,
            normal: normal,
            pointQ: closest.point,
            penetration: penetration,
            allowedSide: allowedSide
        )
    }

    private static func bubblePairID(
        _ first: ReferenceBubbleID,
        _ second: ReferenceBubbleID
    ) -> ReferenceContactID {
        let low = UInt64(UInt32(truncatingIfNeeded: min(first.rawValue, second.rawValue)))
        let high = UInt64(UInt32(truncatingIfNeeded: max(first.rawValue, second.rawValue)))
        return ReferenceContactID(rawValue: (low << 32) | high)
    }

    private static func bubbleSegmentID(
        _ bubble: ReferenceBubbleID,
        _ segment: ReferenceSegmentID
    ) -> ReferenceContactID {
        let bubbleBits = UInt64(UInt32(truncatingIfNeeded: bubble.rawValue))
        let segmentBits = UInt64(UInt32(truncatingIfNeeded: segment.rawValue))
        return ReferenceContactID(rawValue: (1 << 63) | (bubbleBits << 32) | segmentBits)
    }
}
