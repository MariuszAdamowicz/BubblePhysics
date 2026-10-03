import Foundation

public enum ContourSampler {
    public static func pointCount(radius: Double, maxArcSpacing: Double) -> Int {
        guard radius.isFinite, maxArcSpacing.isFinite,
              radius > 0, maxArcSpacing > 0 else { return 8 }
        return max(8, Int(ceil(2 * Double.pi * radius / maxArcSpacing)))
    }

    public static func makeCircle(
        center: BPVector,
        radius: Double,
        maxArcSpacing: Double
    ) -> [ContourPoint] {
        let count = pointCount(radius: radius, maxArcSpacing: maxArcSpacing)
        return (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return ContourPoint(position: center + BPVector(
                x: cos(angle) * radius,
                y: sin(angle) * radius
            ))
        }
    }

    public static func resampleClosedContour(
        _ points: [ContourPoint],
        targetCount: Int
    ) -> [ContourPoint] {
        guard let first = points.first else { return [] }
        let count = max(3, targetCount)
        guard points.count > 1 else {
            return Array(repeating: first, count: count)
        }

        var cumulative = [Double](repeating: 0, count: points.count + 1)
        for index in points.indices {
            let next = (index + 1) % points.count
            cumulative[index + 1] = cumulative[index]
                + (points[next].position - points[index].position).length
        }

        let perimeter = cumulative[points.count]
        guard perimeter > 1e-12, perimeter.isFinite else {
            return Array(repeating: first, count: count)
        }

        var segment = 0
        var result: [ContourPoint] = []
        result.reserveCapacity(count)
        for sample in 0..<count {
            let distance = perimeter * Double(sample) / Double(count)
            while segment + 1 < points.count && cumulative[segment + 1] < distance {
                segment += 1
            }
            let next = (segment + 1) % points.count
            let segmentLength = cumulative[segment + 1] - cumulative[segment]
            let fraction = segmentLength > 1e-12
                ? (distance - cumulative[segment]) / segmentLength
                : 0
            let position = points[segment].position
                + (points[next].position - points[segment].position) * fraction
            result.append(ContourPoint(position: position))
        }

        if signedArea(points) > 0, signedArea(result) < 0 {
            result.reverse()
        }
        return result
    }

    private static func signedArea(_ points: [ContourPoint]) -> Double {
        guard points.count >= 3 else { return 0 }
        return points.indices.reduce(0) { area, index in
            area + points[index].position.cross(points[(index + 1) % points.count].position)
        } * 0.5
    }
}
