public enum ContourContactDirection: UInt32, Equatable, Sendable {
    case firstPointAgainstSecondEdge
    case secondPointAgainstFirstEdge
    case edgeCrossing
}

public struct ContourContact: Equatable, Sendable {
    public let pointIndex: Int
    public let edgeStartIndex: Int
    public let edgeEndIndex: Int
    public let barycentric: Float
    public let normal: Vector2
    public let penetration: Float
    public let sourceID: UInt64
    public let direction: ContourContactDirection

    public init(
        pointIndex: Int,
        edgeStartIndex: Int,
        edgeEndIndex: Int,
        barycentric: Float,
        normal: Vector2,
        penetration: Float,
        sourceID: UInt64,
        direction: ContourContactDirection
    ) {
        self.pointIndex = pointIndex
        self.edgeStartIndex = edgeStartIndex
        self.edgeEndIndex = edgeEndIndex
        self.barycentric = barycentric
        self.normal = normal
        self.penetration = penetration
        self.sourceID = sourceID
        self.direction = direction
    }
}

public enum ContourContactReference {
    public struct NearestPoint: Equatable, Sendable {
        public let point: Vector2
        public let barycentric: Float
        public let distance: Float
    }

    public static func contains(_ point: Vector2, contour: [Vector2]) -> Bool {
        guard contour.count >= 3 else { return false }
        var inside = false
        for index in contour.indices {
            let start = contour[index]
            let end = contour[(index + 1) % contour.count]
            let nearest = nearestPoint(to: point, segmentStart: start, segmentEnd: end)
            if nearest.distance <= 1e-6 { return true }
            if (start.y > point.y) != (end.y > point.y) {
                let crossingX = (end.x - start.x) * (point.y - start.y) / (end.y - start.y) + start.x
                if point.x < crossingX { inside.toggle() }
            }
        }
        return inside
    }

    public static func nearestPoint(to point: Vector2, segmentStart: Vector2, segmentEnd: Vector2) -> NearestPoint {
        let direction = segmentEnd - segmentStart
        let lengthSquared = direction.dot(direction)
        let barycentric = lengthSquared > 1e-12
            ? max(0, min(1, (point - segmentStart).dot(direction) / lengthSquared))
            : 0
        let projection = segmentStart + direction * barycentric
        let delta = projection - point
        return NearestPoint(point: projection, barycentric: barycentric, distance: delta.dot(delta).squareRoot())
    }

    public static func contacts(first: [Vector2], second: [Vector2]) -> [ContourContact] {
        guard first.count >= 3, second.count >= 3 else { return [] }
        var result: [ContourContact] = []
        appendContainedPoints(first, against: second, direction: .firstPointAgainstSecondEdge, to: &result)
        appendContainedPoints(second, against: first, direction: .secondPointAgainstFirstEdge, to: &result)
        appendCrossings(first, second, to: &result)
        return result.sorted { $0.sourceID < $1.sourceID }
    }

    private static func appendContainedPoints(
        _ points: [Vector2],
        against contour: [Vector2],
        direction: ContourContactDirection,
        to result: inout [ContourContact]
    ) {
        for pointIndex in points.indices where contains(points[pointIndex], contour: contour) {
            var best: (edge: Int, nearest: NearestPoint)?
            for edge in contour.indices {
                let nearest = nearestPoint(
                    to: points[pointIndex],
                    segmentStart: contour[edge],
                    segmentEnd: contour[(edge + 1) % contour.count]
                )
                if best == nil || nearest.distance < best!.nearest.distance {
                    best = (edge, nearest)
                }
            }
            guard let best else { continue }
            let edgeEnd = (best.edge + 1) % contour.count
            let delta = best.nearest.point - points[pointIndex]
            let normal = normalizedOrEdgeNormal(delta, edge: contour[edgeEnd] - contour[best.edge])
            result.append(ContourContact(
                pointIndex: pointIndex,
                edgeStartIndex: best.edge,
                edgeEndIndex: edgeEnd,
                barycentric: best.nearest.barycentric,
                normal: normal,
                penetration: best.nearest.distance,
                sourceID: sourceID(direction: direction, firstFeature: pointIndex, secondFeature: best.edge),
                direction: direction
            ))
        }
    }

    private static func appendCrossings(_ first: [Vector2], _ second: [Vector2], to result: inout [ContourContact]) {
        for firstEdge in first.indices {
            let firstEnd = (firstEdge + 1) % first.count
            for secondEdge in second.indices {
                let secondEnd = (secondEdge + 1) % second.count
                guard let intersection = intersection(
                    first[firstEdge], first[firstEnd], second[secondEdge], second[secondEnd]
                ) else { continue }
                let firstDirection = first[firstEnd] - first[firstEdge]
                result.append(ContourContact(
                    pointIndex: firstEdge,
                    edgeStartIndex: secondEdge,
                    edgeEndIndex: secondEnd,
                    barycentric: intersection.secondBarycentric,
                    normal: normalizedOrEdgeNormal(Vector2(x: -firstDirection.y, y: firstDirection.x), edge: firstDirection),
                    penetration: 0,
                    sourceID: sourceID(direction: .edgeCrossing, firstFeature: firstEdge, secondFeature: secondEdge),
                    direction: .edgeCrossing
                ))
            }
        }
    }

    private static func intersection(
        _ firstStart: Vector2, _ firstEnd: Vector2,
        _ secondStart: Vector2, _ secondEnd: Vector2
    ) -> (firstBarycentric: Float, secondBarycentric: Float)? {
        let firstDirection = firstEnd - firstStart
        let secondDirection = secondEnd - secondStart
        let denominator = cross(firstDirection, secondDirection)
        guard abs(denominator) > 1e-7 else { return nil }
        let offset = secondStart - firstStart
        let firstBarycentric = cross(offset, secondDirection) / denominator
        let secondBarycentric = cross(offset, firstDirection) / denominator
        guard firstBarycentric >= 0, firstBarycentric <= 1, secondBarycentric >= 0, secondBarycentric <= 1 else { return nil }
        return (firstBarycentric, secondBarycentric)
    }

    private static func sourceID(direction: ContourContactDirection, firstFeature: Int, secondFeature: Int) -> UInt64 {
        (UInt64(direction.rawValue) << 56) |
            (UInt64(UInt32(firstFeature)) << 28) |
            UInt64(UInt32(secondFeature) & 0x0fff_ffff)
    }

    private static func normalizedOrEdgeNormal(_ vector: Vector2, edge: Vector2) -> Vector2 {
        let squared = vector.dot(vector)
        if squared > 1e-12 { return vector * (1 / squared.squareRoot()) }
        let fallback = Vector2(x: -edge.y, y: edge.x)
        let fallbackSquared = fallback.dot(fallback)
        return fallbackSquared > 1e-12 ? fallback * (1 / fallbackSquared.squareRoot()) : Vector2(x: 1, y: 0)
    }

    private static func cross(_ first: Vector2, _ second: Vector2) -> Float {
        first.x * second.y - first.y * second.x
    }
}
