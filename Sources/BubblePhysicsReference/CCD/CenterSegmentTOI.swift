public enum ReferenceCenterSegmentTOI {
    public static func firstIntersection(
        bubble: ReferenceBubble, segment: ReferenceSegment, tolerance: Float
    ) -> TimeOfImpactResult {
        let p0 = bubble.previousCenter
        let dp = bubble.center - p0
        let a0 = segment.previousA
        let da = segment.currentA - a0
        let v0 = segment.previousB - segment.previousA
        let dv = (segment.currentB - segment.currentA) - v0
        let u0 = p0 - a0
        let du = dp - da
        let c0 = u0.cross(v0)
        let c1 = du.cross(v0) + u0.cross(dv)
        let c2 = du.cross(dv)
        let epsilon = max(abs(tolerance), 1e-7)

        var roots: [Float] = []
        if abs(c2) <= epsilon {
            guard abs(c1) > epsilon else { return .none }
            roots = [-c0 / c1]
        } else {
            let discriminant = c1 * c1 - 4 * c2 * c0
            guard discriminant >= -epsilon else { return .none }
            let root = max(0, discriminant).squareRoot()
            roots = [(-c1 - root) / (2 * c2), (-c1 + root) / (2 * c2)].sorted()
        }

        for t in roots where t >= -epsilon && t <= 1 + epsilon {
            let fraction = min(1, max(0, t))
            let p = p0 + dp * fraction
            let a = a0 + da * fraction
            let b = a + v0 + dv * fraction
            let edge = b - a
            let lengthSquared = edge.lengthSquared
            guard lengthSquared > Float.ulpOfOne else { continue }
            let projection = (p - a).dot(edge) / lengthSquared
            guard projection >= -epsilon && projection <= 1 + epsilon else { continue }

            let sample = min(0.0001, max(epsilon, 0.000001))
            let before = polynomial(c0, c1, c2, max(0, fraction - sample))
            let after = polynomial(c0, c1, c2, min(1, fraction + sample))
            guard abs(before) > epsilon || abs(after) > epsilon else { continue }
            guard before * after <= epsilon || fraction == 0 || fraction == 1 else { continue }
            let baseNormal = ReferenceVector2(x: -edge.y, y: edge.x).normalized(or: .init(x: 0, y: 1))
            let side = before < 0 ? -Float(1) : Float(1)
            return .impact(fraction: fraction, normal: baseNormal * side, point: a + edge * min(1, max(0, projection)))
        }
        return .none
    }

    private static func polynomial(_ c0: Float, _ c1: Float, _ c2: Float, _ t: Float) -> Float {
        (c2 * t + c1) * t + c0
    }
}
