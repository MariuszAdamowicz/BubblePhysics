struct BubbleContact: Sendable {
    let firstVertex: Int
    let secondVertex: Int
    let normal: Vector2
    let penetration: Float
}

enum BubbleContactGenerator {
    static func contacts(between first: BubbleTopology, and second: BubbleTopology) -> [BubbleContact] {
        guard first.boundaryPoints.count >= 3, second.boundaryPoints.count >= 3 else { return [] }
        var contacts: [BubbleContact] = []

        for index in first.boundaryPoints.indices where pointIsInsidePolygon(first.boundaryPoints[index], polygon: second.boundaryPoints) {
            guard let nearest = nearestEdge(to: first.boundaryPoints[index], polygon: second.boundaryPoints) else { continue }
            let normal = normalized(nearest.projection - first.boundaryPoints[index])
            let secondVertex = nearest.startDistance <= nearest.endDistance ? nearest.index : (nearest.index + 1) % second.boundaryPoints.count
            contacts.append(BubbleContact(firstVertex: index, secondVertex: secondVertex, normal: normal, penetration: nearest.distance + 0.01))
        }

        for index in second.boundaryPoints.indices where pointIsInsidePolygon(second.boundaryPoints[index], polygon: first.boundaryPoints) {
            guard let nearest = nearestEdge(to: second.boundaryPoints[index], polygon: first.boundaryPoints) else { continue }
            let outwardForSecond = normalized(nearest.projection - second.boundaryPoints[index])
            let firstVertex = nearest.startDistance <= nearest.endDistance ? nearest.index : (nearest.index + 1) % first.boundaryPoints.count
            contacts.append(BubbleContact(firstVertex: firstVertex, secondVertex: index, normal: outwardForSecond * -1, penetration: nearest.distance + 0.01))
        }

        for firstIndex in first.boundaryPoints.indices {
            let firstNext = (firstIndex + 1) % first.boundaryPoints.count
            let firstEdge = Segment(start: first.boundaryPoints[firstIndex], end: first.boundaryPoints[firstNext])
            for secondIndex in second.boundaryPoints.indices {
                let secondNext = (secondIndex + 1) % second.boundaryPoints.count
                let secondEdge = Segment(start: second.boundaryPoints[secondIndex], end: second.boundaryPoints[secondNext])
                guard segmentsIntersect(firstEdge, secondEdge), let intersection = segmentIntersection(firstEdge, secondEdge) else { continue }
                let firstVertex = squaredLength(first.boundaryPoints[firstIndex] - intersection) <= squaredLength(first.boundaryPoints[firstNext] - intersection) ? firstIndex : firstNext
                let secondVertex = squaredLength(second.boundaryPoints[secondIndex] - intersection) <= squaredLength(second.boundaryPoints[secondNext] - intersection) ? secondIndex : secondNext
                let centerNormal = normalized(first.center - second.center)
                let fallback = normalized(Vector2(x: -(firstEdge.end - firstEdge.start).y, y: (firstEdge.end - firstEdge.start).x))
                contacts.append(BubbleContact(firstVertex: firstVertex, secondVertex: secondVertex, normal: centerNormal == .zero ? fallback : centerNormal, penetration: 0.01))
            }
        }
        return contacts
    }

    private static func pointIsInsidePolygon(_ point: Vector2, polygon: [Vector2]) -> Bool {
        var inside = false
        for index in polygon.indices {
            let first = polygon[index]
            let second = polygon[(index + 1) % polygon.count]
            if abs(orientation(first, second, point)) < 0.00001,
               point.x >= min(first.x, second.x), point.x <= max(first.x, second.x),
               point.y >= min(first.y, second.y), point.y <= max(first.y, second.y) { return true }
            let crosses = (first.y > point.y) != (second.y > point.y)
            if crosses {
                let xAtY = (second.x - first.x) * (point.y - first.y) / (second.y - first.y) + first.x
                if point.x < xAtY { inside.toggle() }
            }
        }
        return inside
    }

    private static func nearestEdge(to point: Vector2, polygon: [Vector2]) -> (index: Int, projection: Vector2, distance: Float, startDistance: Float, endDistance: Float)? {
        var result: (index: Int, projection: Vector2, distance: Float, startDistance: Float, endDistance: Float)?
        for index in polygon.indices {
            let start = polygon[index]
            let end = polygon[(index + 1) % polygon.count]
            let direction = end - start
            let denominator = squaredLength(direction)
            guard denominator > 0 else { continue }
            let t = max(0, min(1, (point - start).dot(direction) / denominator))
            let projection = start + direction * t
            let distance = length(projection - point)
            if result == nil || distance < result!.distance {
                result = (index, projection, distance, length(projection - start), length(projection - end))
            }
        }
        return result
    }

    private static func segmentIntersection(_ first: Segment, _ second: Segment) -> Vector2? {
        let direction = first.end - first.start
        let otherDirection = second.end - second.start
        let denominator = cross(direction, otherDirection)
        guard abs(denominator) > 0.00001 else { return nil }
        let t = cross(second.start - first.start, otherDirection) / denominator
        return first.start + direction * t
    }
}
