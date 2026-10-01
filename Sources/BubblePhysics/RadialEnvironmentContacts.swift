import Foundation

public enum RadialEnvironmentContacts {
    public static func generate(
        bubble: RadialBubbleState,
        bounds: AABB,
        polygons: [SimulationPolygonSnapshot]
    ) -> [RadialSurfaceContact] {
        var contacts: [RadialSurfaceContact] = []
        let points = bubble.surfacePoints

        for index in points.indices {
            let point = points[index]
            let velocity = surfaceVelocity(of: bubble, sensorIndex: index)
            appendWallContact(point.x < bounds.minimum.x, sensor: index, sensorCount: bubble.sensors.count, point: point,
                              normal: Vector2(x: 1, y: 0), penetration: bounds.minimum.x - point.x,
                              velocity: velocity, wallCode: 0, to: &contacts)
            appendWallContact(point.x > bounds.maximum.x, sensor: index, sensorCount: bubble.sensors.count, point: point,
                              normal: Vector2(x: -1, y: 0), penetration: point.x - bounds.maximum.x,
                              velocity: velocity, wallCode: 1, to: &contacts)
            appendWallContact(point.y < bounds.minimum.y, sensor: index, sensorCount: bubble.sensors.count, point: point,
                              normal: Vector2(x: 0, y: 1), penetration: bounds.minimum.y - point.y,
                              velocity: velocity, wallCode: 2, to: &contacts)
            appendWallContact(point.y > bounds.maximum.y, sensor: index, sensorCount: bubble.sensors.count, point: point,
                              normal: Vector2(x: 0, y: -1), penetration: point.y - bounds.maximum.y,
                              velocity: velocity, wallCode: 3, to: &contacts)
        }

        for polygon in polygons where polygon.worldVertices.count >= 3 {
            appendPolygonContacts(bubble: bubble, points: points, polygon: polygon, to: &contacts)
        }

        return contacts.sorted { $0.sourceID < $1.sourceID }
    }

    private static func appendWallContact(
        _ condition: Bool,
        sensor: Int,
        sensorCount: Int,
        point: Vector2,
        normal: Vector2,
        penetration: Float,
        velocity: Vector2,
        wallCode: UInt64,
        to contacts: inout [RadialSurfaceContact]
    ) {
        guard condition, penetration > 0 else { return }
        contacts.append(RadialSurfaceContact(
            sensorStartIndex: sensor,
            sensorEndIndex: (sensor + 1) % sensorCount,
            barycentric: 0,
            point: point,
            normal: normal,
            penetration: penetration,
            relativeVelocity: velocity,
            sourceID: (wallCode << 56) | UInt64(sensor)
        ))
    }

    private static func appendPolygonContacts(
        bubble: RadialBubbleState,
        points: [Vector2],
        polygon: SimulationPolygonSnapshot,
        to contacts: inout [RadialSurfaceContact]
    ) {
        for index in points.indices where ContourContactReference.contains(points[index], contour: polygon.worldVertices) {
            var bestEdge = 0
            var best = ContourContactReference.nearestPoint(
                to: points[index],
                segmentStart: polygon.worldVertices[0],
                segmentEnd: polygon.worldVertices[1]
            )
            for edge in polygon.worldVertices.indices.dropFirst() {
                let candidate = ContourContactReference.nearestPoint(
                    to: points[index],
                    segmentStart: polygon.worldVertices[edge],
                    segmentEnd: polygon.worldVertices[(edge + 1) % polygon.worldVertices.count]
                )
                if candidate.distance < best.distance {
                    bestEdge = edge
                    best = candidate
                }
            }
            let edgeVector = polygon.worldVertices[(bestEdge + 1) % polygon.worldVertices.count]
                - polygon.worldVertices[bestEdge]
            let delta = best.point - points[index]
            let normal = normalized(delta, fallback: Vector2(x: edgeVector.y, y: -edgeVector.x))
            let polygonVelocity = polygonSurfaceVelocity(polygon, at: points[index])
            contacts.append(RadialSurfaceContact(
                sensorStartIndex: index,
                sensorEndIndex: (index + 1) % bubble.sensors.count,
                barycentric: 0,
                point: points[index],
                normal: normal,
                penetration: best.distance,
                relativeVelocity: surfaceVelocity(of: bubble, sensorIndex: index) - polygonVelocity,
                sourceID: (UInt64(0x10) << 56)
                    | (UInt64(UInt32(polygon.id.rawValue)) << 32)
                    | UInt64(UInt32(index))
            ))
        }
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

    private static func polygonSurfaceVelocity(
        _ polygon: SimulationPolygonSnapshot,
        at point: Vector2
    ) -> Vector2 {
        guard polygon.mode == .kinematic else { return .zero }
        let arm = point - polygon.position
        return polygon.linearVelocity
            + Vector2(x: -polygon.angularVelocity * arm.y, y: polygon.angularVelocity * arm.x)
    }

    private static func normalized(_ vector: Vector2, fallback: Vector2) -> Vector2 {
        let squared = vector.dot(vector)
        if squared > 1e-12 { return vector * (1 / squared.squareRoot()) }
        let fallbackSquared = fallback.dot(fallback)
        return fallbackSquared > 1e-12 ? fallback * (1 / fallbackSquared.squareRoot()) : Vector2(x: 1, y: 0)
    }
}
