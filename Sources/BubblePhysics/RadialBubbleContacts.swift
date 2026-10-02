import Foundation

public struct RadialBubblePairContact: Equatable, Sendable {
    public let firstStartIndex: Int
    public let firstEndIndex: Int
    public let firstBarycentric: Float
    public let secondStartIndex: Int
    public let secondEndIndex: Int
    public let secondBarycentric: Float
    public let point: Vector2
    public let normal: Vector2
    public let penetration: Float
    public let relativeVelocity: Vector2
}

public struct RadialBubblePairLoads: Equatable, Sendable {
    public let first: RadialBodyLoad
    public let second: RadialBodyLoad
}

public enum RadialBubbleContacts {
    public static func generate(
        first: RadialBubbleState,
        second: RadialBubbleState
    ) -> [RadialBubblePairContact] {
        let firstPoints = first.surfacePoints
        let secondPoints = second.surfacePoints
        var contacts: [RadialBubblePairContact] = []

        for firstStart in firstPoints.indices {
            let firstEnd = (firstStart + 1) % firstPoints.count
            for secondStart in secondPoints.indices {
                let secondEnd = (secondStart + 1) % secondPoints.count
                guard let crossing = RadialSegmentGeometry.intersection(
                    (firstPoints[firstStart], firstPoints[firstEnd]),
                    (secondPoints[secondStart], secondPoints[secondEnd])
                ) else { continue }
                let centerDelta = first.body.center - second.body.center
                let edge = secondPoints[secondEnd] - secondPoints[secondStart]
                var normal = normalized(Vector2(x: edge.y, y: -edge.x), fallback: centerDelta)
                if normal.dot(centerDelta) < 0 { normal = normal * -1 }
                contacts.append(contact(
                    first: first, second: second,
                    firstStart: firstStart, firstT: crossing.firstParameter,
                    secondStart: secondStart, secondT: crossing.secondParameter,
                    point: crossing.point, normal: normal, penetration: 1e-4
                ))
            }
        }

        appendContainedSensors(
            inner: first, innerPoints: firstPoints, outer: second, outerPoints: secondPoints,
            innerIsFirst: true, to: &contacts
        )
        appendContainedSensors(
            inner: second, innerPoints: secondPoints, outer: first, outerPoints: firstPoints,
            innerIsFirst: false, to: &contacts
        )
        return contacts
    }

    public static func reduce(
        contacts: [RadialBubblePairContact],
        first: RadialBubbleState,
        second: RadialBubbleState
    ) -> RadialBubblePairLoads {
        var firstLoad = RadialBodyLoad.zero(sensorCount: first.sensors.count)
        var secondLoad = RadialBodyLoad.zero(sensorCount: second.sensors.count)

        for contact in contacts {
            let closingSpeed = max(0, -contact.relativeVelocity.dot(contact.normal))
            let elastic = 0.5 * (
                first.material.springForce(extension: contact.penetration)
                    + second.material.springForce(extension: contact.penetration)
            )
            let damping = closingSpeed * 0.5 * (first.material.drag + second.material.drag)
            let magnitude = max(0, elastic + damping)
            guard magnitude.isFinite else { continue }
            let force = contact.normal * magnitude
            firstLoad.force = firstLoad.force + force
            secondLoad.force = secondLoad.force - force
            firstLoad.torque += cross(contact.point - first.body.center, force)
            secondLoad.torque += cross(contact.point - second.body.center, force * -1)
            distribute(
                penetration: contact.penetration, pressure: magnitude,
                start: contact.firstStartIndex, end: contact.firstEndIndex,
                barycentric: contact.firstBarycentric, into: &firstLoad
            )
            distribute(
                penetration: contact.penetration, pressure: magnitude,
                start: contact.secondStartIndex, end: contact.secondEndIndex,
                barycentric: contact.secondBarycentric, into: &secondLoad
            )
        }
        return RadialBubblePairLoads(first: firstLoad, second: secondLoad)
    }

    private static func appendContainedSensors(
        inner: RadialBubbleState,
        innerPoints: [Vector2],
        outer: RadialBubbleState,
        outerPoints: [Vector2],
        innerIsFirst: Bool,
        to contacts: inout [RadialBubblePairContact]
    ) {
        for innerIndex in innerPoints.indices
            where RadialSegmentGeometry.contains(innerPoints[innerIndex], contour: outerPoints) {
            let nearest = nearestSegment(to: innerPoints[innerIndex], points: outerPoints)
            guard nearest.distance > 1e-6 else { continue }
            let outward = normalized(nearest.point - innerPoints[innerIndex], fallback: inner.body.center - outer.body.center)
            if innerIsFirst {
                contacts.append(contact(
                    first: inner, second: outer,
                    firstStart: innerIndex, firstT: 0,
                    secondStart: nearest.start, secondT: nearest.parameter,
                    point: innerPoints[innerIndex], normal: outward, penetration: nearest.distance
                ))
            } else {
                contacts.append(contact(
                    first: outer, second: inner,
                    firstStart: nearest.start, firstT: nearest.parameter,
                    secondStart: innerIndex, secondT: 0,
                    point: innerPoints[innerIndex], normal: outward * -1, penetration: nearest.distance
                ))
            }
        }
    }

    private static func contact(
        first: RadialBubbleState, second: RadialBubbleState,
        firstStart: Int, firstT: Float, secondStart: Int, secondT: Float,
        point: Vector2, normal: Vector2, penetration: Float
    ) -> RadialBubblePairContact {
        let firstEnd = (firstStart + 1) % first.sensors.count
        let secondEnd = (secondStart + 1) % second.sensors.count
        return RadialBubblePairContact(
            firstStartIndex: firstStart, firstEndIndex: firstEnd, firstBarycentric: firstT,
            secondStartIndex: secondStart, secondEndIndex: secondEnd, secondBarycentric: secondT,
            point: point, normal: normal, penetration: penetration,
            relativeVelocity: velocity(first, from: firstStart, to: firstEnd, at: firstT)
                - velocity(second, from: secondStart, to: secondEnd, at: secondT)
        )
    }

    private static func nearestSegment(
        to point: Vector2, points: [Vector2]
    ) -> (point: Vector2, distance: Float, start: Int, parameter: Float) {
        var result = (points[0], Float.greatestFiniteMagnitude, 0, Float.zero)
        for start in points.indices {
            let candidate = RadialSegmentGeometry.nearestPoints(
                (point, point), (points[start], points[(start + 1) % points.count])
            )
            if candidate.distance < result.1 {
                result = (candidate.secondPoint, candidate.distance, start, candidate.secondParameter)
            }
        }
        return (result.0, result.1, result.2, result.3)
    }

    private static func velocity(
        _ bubble: RadialBubbleState, from start: Int, to end: Int, at t: Float
    ) -> Vector2 {
        sensorVelocity(bubble, index: start) * (1 - t) + sensorVelocity(bubble, index: end) * t
    }

    private static func sensorVelocity(_ bubble: RadialBubbleState, index: Int) -> Vector2 {
        let point = bubble.surfacePoint(at: index)
        let arm = point - bubble.body.center
        let angle = bubble.body.angle + bubble.sensors[index].materialAngle
        return bubble.body.linearVelocity
            + Vector2(x: -bubble.body.angularVelocity * arm.y, y: bubble.body.angularVelocity * arm.x)
            + Vector2(x: cos(angle), y: sin(angle)) * bubble.sensors[index].radialVelocity
    }

    private static func distribute(
        penetration: Float, pressure: Float, start: Int, end: Int,
        barycentric: Float, into load: inout RadialBodyLoad
    ) {
        let startWeight = 1 - barycentric
        load.sensorCompression[start] += penetration * startWeight
        load.sensorCompression[end] += penetration * barycentric
        load.sensorPressureDeltas[start] += pressure * startWeight
        load.sensorPressureDeltas[end] += pressure * barycentric
    }

    private static func normalized(_ vector: Vector2, fallback: Vector2) -> Vector2 {
        let squared = vector.dot(vector)
        if squared > 1e-12 { return vector * (1 / squared.squareRoot()) }
        let fallbackSquared = fallback.dot(fallback)
        return fallbackSquared > 1e-12 ? fallback * (1 / fallbackSquared.squareRoot()) : Vector2(x: 1, y: 0)
    }

    private static func cross(_ a: Vector2, _ b: Vector2) -> Float { a.x * b.y - a.y * b.x }
}
