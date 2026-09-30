struct PolygonContact: Sendable {
    let bubbleVertex: Int
    let normal: Vector2
    let penetration: Float
    let surfaceVelocity: Vector2
}

enum PolygonContactGenerator {
    static func contacts(bubble: BubbleTopology, polygon: RigidPolygon) -> [PolygonContact] {
        bubble.boundaryPoints.indices.compactMap { index in
            let point = bubble.boundaryPoints[index]
            guard contains(point, in: polygon), let nearest = nearestEdge(to: point, edges: polygon.worldBoundaryEdges) else { return nil }
            return PolygonContact(
                bubbleVertex: index,
                normal: normalized(nearest.projection - point),
                penetration: nearest.distance + 0.01,
                surfaceVelocity: polygon.surfaceVelocity(at: nearest.projection)
            )
        }
    }

    static func contains(_ point: Vector2, in polygon: RigidPolygon) -> Bool {
        let vertices = polygon.worldVertices
        var inside = false
        for index in vertices.indices {
            let first = vertices[index]
            let second = vertices[(index + 1) % vertices.count]
            if abs(orientation(first, second, point)) < 0.00001,
               point.x >= min(first.x, second.x), point.x <= max(first.x, second.x),
               point.y >= min(first.y, second.y), point.y <= max(first.y, second.y) { return true }
            if (first.y > point.y) != (second.y > point.y) {
                let xAtY = (second.x - first.x) * (point.y - first.y) / (second.y - first.y) + first.x
                if point.x < xAtY { inside.toggle() }
            }
        }
        return inside
    }

    private static func nearestEdge(to point: Vector2, edges: [Segment]) -> (projection: Vector2, distance: Float)? {
        var best: (projection: Vector2, distance: Float)?
        for edge in edges {
            let direction = edge.end - edge.start
            let denominator = squaredLength(direction)
            guard denominator > 0 else { continue }
            let t = max(0, min(1, (point - edge.start).dot(direction) / denominator))
            let projection = edge.start + direction * t
            let distance = length(projection - point)
            if best == nil || distance < best!.distance { best = (projection, distance) }
        }
        return best
    }
}
