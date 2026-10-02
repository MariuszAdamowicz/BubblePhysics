import Foundation

public enum RadialEnvironmentContacts {
    public static func generate(
        bubble: RadialBubbleState,
        bounds: AABB,
        polygons: [SimulationPolygonSnapshot]
    ) -> [RadialSurfaceContact] {
        let points = bubble.surfacePoints
        var contacts: [RadialSurfaceContact] = []
        for start in points.indices {
            appendWallContacts(
                bubble: bubble, start: start, end: (start + 1) % points.count,
                bounds: bounds, to: &contacts
            )
        }
        for polygon in polygons where polygon.worldVertices.count >= 3 {
            appendPolygonContacts(bubble: bubble, points: points, polygon: polygon, to: &contacts)
        }
        return contacts.sorted(by: stableOrder)
    }

    private static func appendWallContacts(
        bubble: RadialBubbleState, start: Int, end: Int, bounds: AABB,
        to contacts: inout [RadialSurfaceContact]
    ) {
        let a = bubble.surfacePoint(at: start)
        let b = bubble.surfacePoint(at: end)
        let walls: [(Vector2, Float, Float, UInt64)] = [
            (Vector2(x: 1, y: 0), bounds.minimum.x - a.x, bounds.minimum.x - b.x, 0),
            (Vector2(x: -1, y: 0), a.x - bounds.maximum.x, b.x - bounds.maximum.x, 1),
            (Vector2(x: 0, y: 1), bounds.minimum.y - a.y, bounds.minimum.y - b.y, 2),
            (Vector2(x: 0, y: -1), a.y - bounds.maximum.y, b.y - bounds.maximum.y, 3)
        ]
        for (normal, depthA, depthB, code) in walls {
            guard let t = outsideMidpointParameter(depthA, depthB) else { continue }
            let penetration = lerp(depthA, depthB, t)
            guard penetration > 0 else { continue }
            contacts.append(RadialSurfaceContact(
                sensorStartIndex: start, sensorEndIndex: end, barycentric: t,
                point: lerp(a, b, t), normal: normal, penetration: penetration,
                relativeVelocity: surfaceVelocity(of: bubble, from: start, to: end, at: t),
                sourceID: (code << 56) | UInt64(start)
            ))
        }
    }

    private static func appendPolygonContacts(
        bubble: RadialBubbleState, points: [Vector2], polygon: SimulationPolygonSnapshot,
        to contacts: inout [RadialSurfaceContact]
    ) {
        let center = polygon.worldVertices.reduce(Vector2.zero, +) * (1 / Float(polygon.worldVertices.count))

        for start in points.indices {
            let end = (start + 1) % points.count
            for edgeIndex in polygon.worldVertices.indices {
                let edgeStart = polygon.worldVertices[edgeIndex]
                let edgeEnd = polygon.worldVertices[(edgeIndex + 1) % polygon.worldVertices.count]
                guard let crossing = RadialSegmentGeometry.intersection(
                    (points[start], points[end]), (edgeStart, edgeEnd)
                ) else { continue }
                let edge = edgeEnd - edgeStart
                var normal = normalized(Vector2(x: edge.y, y: -edge.x), fallback: Vector2(x: 1, y: 0))
                if normal.dot(crossing.point - center) < 0 { normal = normal * -1 }
                contacts.append(RadialSurfaceContact(
                    sensorStartIndex: start, sensorEndIndex: end,
                    barycentric: crossing.firstParameter, point: crossing.point,
                    normal: normal, penetration: 1e-4,
                    relativeVelocity: surfaceVelocity(
                        of: bubble, from: start, to: end, at: crossing.firstParameter
                    ) - polygonSurfaceVelocity(polygon, at: crossing.point),
                    sourceID: polygonSourceID(polygon, feature: edgeIndex, segment: start)
                ))
            }
        }

        for sensor in points.indices
            where RadialSegmentGeometry.contains(points[sensor], contour: polygon.worldVertices) {
            let nearest = nearestPolygonEdge(to: points[sensor], polygon: polygon.worldVertices)
            guard nearest.distance > 1e-6 else { continue }
            contacts.append(RadialSurfaceContact(
                sensorStartIndex: sensor, sensorEndIndex: (sensor + 1) % points.count,
                barycentric: 0, point: points[sensor],
                normal: normalized(nearest.point - points[sensor], fallback: Vector2(x: 1, y: 0)),
                penetration: nearest.distance,
                relativeVelocity: surfaceVelocity(of: bubble, sensorIndex: sensor)
                    - polygonSurfaceVelocity(polygon, at: points[sensor]),
                sourceID: polygonSourceID(polygon, feature: nearest.edge, segment: sensor) | (UInt64(1) << 55)
            ))
        }

        for (vertexIndex, vertex) in polygon.worldVertices.enumerated()
            where RadialSegmentGeometry.contains(vertex, contour: points) {
            let nearest = nearestBubbleSegment(to: vertex, points: points)
            guard nearest.distance > 1e-6 else { continue }
            let end = (nearest.start + 1) % points.count
            contacts.append(RadialSurfaceContact(
                sensorStartIndex: nearest.start, sensorEndIndex: end,
                barycentric: nearest.parameter, point: nearest.point,
                normal: normalized(nearest.point - vertex, fallback: Vector2(x: 1, y: 0)),
                penetration: nearest.distance,
                relativeVelocity: surfaceVelocity(
                    of: bubble, from: nearest.start, to: end, at: nearest.parameter
                ) - polygonSurfaceVelocity(polygon, at: nearest.point),
                sourceID: polygonSourceID(polygon, feature: vertexIndex, segment: nearest.start)
                    | (UInt64(2) << 54)
            ))
        }
    }

    private static func nearestPolygonEdge(
        to point: Vector2, polygon: [Vector2]
    ) -> (point: Vector2, distance: Float, edge: Int) {
        var result = (polygon[0], Float.greatestFiniteMagnitude, 0)
        for edge in polygon.indices {
            let candidate = RadialSegmentGeometry.nearestPoints(
                (point, point), (polygon[edge], polygon[(edge + 1) % polygon.count])
            )
            if candidate.distance < result.1 { result = (candidate.secondPoint, candidate.distance, edge) }
        }
        return (result.0, result.1, result.2)
    }

    private static func nearestBubbleSegment(
        to point: Vector2, points: [Vector2]
    ) -> (point: Vector2, distance: Float, start: Int, parameter: Float) {
        var result = (points[0], Float.greatestFiniteMagnitude, 0, Float.zero)
        for start in points.indices {
            let candidate = RadialSegmentGeometry.nearestPoints(
                (points[start], points[(start + 1) % points.count]), (point, point)
            )
            if candidate.distance < result.1 {
                result = (candidate.firstPoint, candidate.distance, start, candidate.firstParameter)
            }
        }
        return (result.0, result.1, result.2, result.3)
    }

    private static func outsideMidpointParameter(_ depthA: Float, _ depthB: Float) -> Float? {
        guard depthA > 0 || depthB > 0 else { return nil }
        if depthA > 0, depthB > 0 { return 0.5 }
        let crossing = depthA / (depthA - depthB)
        return depthA > 0 ? crossing * 0.5 : (crossing + 1) * 0.5
    }

    private static func surfaceVelocity(of bubble: RadialBubbleState, sensorIndex: Int) -> Vector2 {
        let point = bubble.surfacePoint(at: sensorIndex)
        let arm = point - bubble.body.center
        let angle = bubble.body.angle + bubble.sensors[sensorIndex].materialAngle
        let radial = Vector2(x: cos(angle), y: sin(angle)) * bubble.sensors[sensorIndex].radialVelocity
        return bubble.body.linearVelocity
            + Vector2(x: -bubble.body.angularVelocity * arm.y, y: bubble.body.angularVelocity * arm.x)
            + radial
    }

    private static func surfaceVelocity(
        of bubble: RadialBubbleState, from start: Int, to end: Int, at parameter: Float
    ) -> Vector2 {
        lerp(
            surfaceVelocity(of: bubble, sensorIndex: start),
            surfaceVelocity(of: bubble, sensorIndex: end), parameter
        )
    }

    private static func polygonSurfaceVelocity(
        _ polygon: SimulationPolygonSnapshot, at point: Vector2
    ) -> Vector2 {
        guard polygon.mode == .kinematic else { return .zero }
        let arm = point - polygon.position
        return polygon.linearVelocity
            + Vector2(x: -polygon.angularVelocity * arm.y, y: polygon.angularVelocity * arm.x)
    }

    private static func polygonSourceID(
        _ polygon: SimulationPolygonSnapshot, feature: Int, segment: Int
    ) -> UInt64 {
        (UInt64(0x10) << 56) | (UInt64(UInt32(polygon.id.rawValue)) << 32)
            | (UInt64(UInt16(truncatingIfNeeded: feature)) << 16)
            | UInt64(UInt16(truncatingIfNeeded: segment))
    }

    private static func stableOrder(_ a: RadialSurfaceContact, _ b: RadialSurfaceContact) -> Bool {
        if a.sourceID != b.sourceID { return a.sourceID < b.sourceID }
        if a.sensorStartIndex != b.sensorStartIndex { return a.sensorStartIndex < b.sensorStartIndex }
        return a.barycentric < b.barycentric
    }

    private static func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float { a + (b - a) * t }
    private static func lerp(_ a: Vector2, _ b: Vector2, _ t: Float) -> Vector2 { a + (b - a) * t }

    private static func normalized(_ vector: Vector2, fallback: Vector2) -> Vector2 {
        let squared = vector.dot(vector)
        if squared > 1e-12 { return vector * (1 / squared.squareRoot()) }
        let fallbackSquared = fallback.dot(fallback)
        return fallbackSquared > 1e-12
            ? fallback * (1 / fallbackSquared.squareRoot()) : Vector2(x: 1, y: 0)
    }
}
