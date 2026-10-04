import Foundation

public enum ReferenceContourGenerator {
    public static func points(
        for bubble: ReferenceBubble,
        contacts: [ReferenceContact],
        segments: [ReferenceSegment] = [],
        configuration: ReferenceConfiguration
    ) -> [ReferenceVector2] {
        let config = configuration.sanitized
        let circumference = 2 * Float.pi * bubble.targetRadius
        let count = max(32, Int(ceilf(circumference / config.maxContourSegmentLength)))
        let constraints = contourConstraints(for: bubble, contacts: contacts, segments: segments)
        return sampledContour(
            center: bubble.center,
            naturalRadius: bubble.targetRadius,
            count: count,
            maximumEdgeLength: config.maxContourSegmentLength,
            constraints: constraints,
            tolerance: config.positionTolerance,
            surfaceTension: config.contourSurfaceTension
        )
    }

    public static func points(
        for bubble: ReferenceBubble,
        configuration: ReferenceConfiguration
    ) -> [ReferenceVector2] {
        points(for: bubble, contacts: [], configuration: configuration)
    }

    private static func contourConstraints(
        for bubble: ReferenceBubble,
        contacts: [ReferenceContact],
        segments: [ReferenceSegment]
    ) -> [ReferenceContourConstraint] {
        let segmentByID = Dictionary(uniqueKeysWithValues: segments.map { ($0.id, $0) })
        return contacts.compactMap { contact -> ReferenceContourConstraint? in
            if contact.kind == .bubbleBubble,
               let halfLength = contact.contourHalfLength,
               halfLength > 0 {
                let tangent = ReferenceVector2(x: -contact.normal.y, y: contact.normal.x)
                    .normalized(or: .init(x: 0, y: 1))
                return .init(
                    contactID: contact.id,
                    pointQ: contact.pointQ,
                    inwardNormal: contact.bubbleA == bubble.id ? -contact.normal : contact.normal,
                    pressure: contact.pressure,
                    finiteSegment: .init(
                        a: contact.pointQ - tangent * halfLength,
                        b: contact.pointQ + tangent * halfLength
                    )
                )
            }
            if contact.kind == .bubbleSegment,
               let segmentID = contact.segment,
               let segment = segmentByID[segmentID] {
                let endpoints = ReferenceSegmentEndpoints(a: segment.currentA, b: segment.currentB)
                let edge = segment.currentB - segment.currentA
                var normal = ReferenceVector2(x: -edge.y, y: edge.x)
                    .normalized(or: contact.normal)
                if let allowedSide = segment.collisionMode.allowedSide {
                    normal = normal * allowedSide
                } else if (bubble.center - segment.currentA).dot(normal) < 0 {
                    normal = -normal
                }
                return .init(
                    contactID: contact.id,
                    pointQ: segment.currentA,
                    inwardNormal: normal,
                    pressure: contact.pressure,
                    finiteSegment: endpoints
                )
            }
            let inward: ReferenceVector2
            if contact.bubbleA == bubble.id {
                inward = contact.kind == .bubbleBubble ? -contact.normal : contact.normal
            } else if contact.bubbleB == bubble.id {
                inward = contact.normal
            } else {
                return nil
            }
            return .init(
                contactID: contact.id,
                pointQ: contact.pointQ,
                inwardNormal: inward,
                pressure: contact.pressure
            )
        }.sorted { $0.contactID < $1.contactID }
    }

    private static func radialLimit(
        from center: ReferenceVector2,
        direction: ReferenceVector2,
        naturalRadius: Float,
        constraints: [ReferenceContourConstraint],
        clearance: Float
    ) -> (radius: Float, constraintIndex: Int?) {
        var radius = naturalRadius
        var limitingIndex: Int?
        for index in constraints.indices {
            let constraint = constraints[index]
            if let segment = constraint.finiteSegment,
               let candidate = rayIntersectionDistance(
                   origin: center, direction: direction, segment: segment
               ), candidate < radius {
                radius = max(0, candidate - clearance)
                limitingIndex = index
                continue
            }
            guard constraint.finiteSegment == nil else { continue }
            let directionalSlope = direction.dot(constraint.inwardNormal)
            guard directionalSlope < -Float.ulpOfOne else { continue }
            let centerDistance = (center - constraint.pointQ).dot(constraint.inwardNormal)
            let candidate = max(0, centerDistance / -directionalSlope)
            if candidate < radius {
                radius = candidate
                limitingIndex = index
            }
        }
        return (radius, limitingIndex)
    }

    private static func sampledContour(
        center: ReferenceVector2,
        naturalRadius: Float,
        count: Int,
        maximumEdgeLength: Float,
        constraints: [ReferenceContourConstraint],
        tolerance: Float,
        surfaceTension: Float
    ) -> [ReferenceVector2] {
        let fullTurn = 2 * Float.pi
        let directions = (0..<count).map { index in
            let angle = fullTurn * Float(index) / Float(count)
            return ReferenceVector2(x: cosf(angle), y: sinf(angle))
        }
        let samples = directions.map {
            radialLimit(
                from: center, direction: $0, naturalRadius: naturalRadius,
                constraints: constraints, clearance: tolerance
            )
        }
        var points = directions.indices.map { center + directions[$0] * samples[$0].radius }
        let allowedLength = maximumEdgeLength + max(tolerance, maximumEdgeLength * 1e-4)
        let naturalTurn = 2 * Float.pi / Float(count)
        let maximumTurn = max(naturalTurn * 2.5, 0.18)
        let relaxation = min(0.8, max(0.25, surfaceTension / (surfaceTension + 10)))

        for pass in 0..<12 {
            var changed = false
            for index in points.indices {
                let radial = (points[index] - center).normalized(or: directions[index])
                let target = center + radial * naturalRadius
                let candidate = points[index] + (target - points[index]) * 0.08
                let projected = projectToAllowedRegion(
                    candidate, center: center, naturalRadius: naturalRadius,
                    constraints: constraints, tolerance: tolerance
                )
                if (projected - points[index]).length > tolerance {
                    points[index] = projected
                    changed = true
                }
            }

            let traversal = pass.isMultiple(of: 2) ? Array(0..<count) : Array((0..<count).reversed())
            for middle in traversal {
                let before = (middle + count - 1) % count
                let after = (middle + 1) % count
                let pointBefore = points[before]
                let pointMiddle = points[middle]
                let pointAfter = points[after]
                let originalScore = localViolation(
                    pointBefore, pointMiddle, pointAfter,
                    maximumEdgeLength: allowedLength, maximumTurn: maximumTurn
                )
                guard originalScore > tolerance else { continue }

                let middleTarget = (pointBefore + pointAfter) * 0.5
                let middleCandidate = projectToAllowedRegion(
                    pointMiddle + (middleTarget - pointMiddle) * relaxation,
                    center: center, naturalRadius: naturalRadius,
                    constraints: constraints, tolerance: tolerance
                )
                let middleScore = localViolation(
                    pointBefore, middleCandidate, pointAfter,
                    maximumEdgeLength: allowedLength, maximumTurn: maximumTurn
                )
                if middleScore + tolerance < originalScore {
                    points[middle] = middleCandidate
                    changed = true
                    continue
                }

                let beforeCandidate = projectToAllowedRegion(
                    pointBefore + (pointMiddle * 2 - pointAfter - pointBefore) * (relaxation * 0.5),
                    center: center, naturalRadius: naturalRadius,
                    constraints: constraints, tolerance: tolerance
                )
                let afterCandidate = projectToAllowedRegion(
                    pointAfter + (pointMiddle * 2 - pointBefore - pointAfter) * (relaxation * 0.5),
                    center: center, naturalRadius: naturalRadius,
                    constraints: constraints, tolerance: tolerance
                )
                let outerScore = localViolation(
                    beforeCandidate, pointMiddle, afterCandidate,
                    maximumEdgeLength: allowedLength, maximumTurn: maximumTurn
                )
                if outerScore + tolerance < originalScore {
                    points[before] = beforeCandidate
                    points[after] = afterCandidate
                    changed = true
                }
            }

            for first in 0..<count {
                let second = (first + 1) % count
                let delta = points[second] - points[first]
                guard delta.length > allowedLength else { continue }
                let correction = delta.normalized(or: directions[second])
                    * ((delta.length - maximumEdgeLength) * 0.5)
                let firstCandidate = projectToAllowedRegion(
                    points[first] + correction, center: center, naturalRadius: naturalRadius,
                    constraints: constraints, tolerance: tolerance
                )
                let secondCandidate = projectToAllowedRegion(
                    points[second] - correction, center: center, naturalRadius: naturalRadius,
                    constraints: constraints, tolerance: tolerance
                )
                if (secondCandidate - firstCandidate).length + tolerance < delta.length {
                    points[first] = firstCandidate
                    points[second] = secondCandidate
                    changed = true
                }
            }
            if !changed { break }
        }

        return points.map {
            projectToAllowedRegion(
                $0, center: center, naturalRadius: naturalRadius,
                constraints: constraints, tolerance: tolerance
            )
        }
    }

    private static func projectToAllowedRegion(
        _ point: ReferenceVector2,
        center: ReferenceVector2,
        naturalRadius: Float,
        constraints: [ReferenceContourConstraint],
        tolerance: Float
    ) -> ReferenceVector2 {
        let offset = point - center
        guard offset.lengthSquared > Float.ulpOfOne else { return center }
        let direction = offset.normalized()
        let limit = radialLimit(
            from: center, direction: direction, naturalRadius: naturalRadius,
            constraints: constraints, clearance: tolerance
        ).radius
        return center + direction * min(offset.length, limit)
    }

    private static func turnAngle(
        incoming: ReferenceVector2,
        outgoing: ReferenceVector2
    ) -> Float {
        guard incoming.lengthSquared > Float.ulpOfOne,
              outgoing.lengthSquared > Float.ulpOfOne else { return .pi }
        let first = incoming.normalized()
        let second = outgoing.normalized()
        return acosf(min(1, max(-1, first.dot(second))))
    }

    private static func localViolation(
        _ before: ReferenceVector2,
        _ middle: ReferenceVector2,
        _ after: ReferenceVector2,
        maximumEdgeLength: Float,
        maximumTurn: Float
    ) -> Float {
        let incoming = middle - before
        let outgoing = after - middle
        let edgeViolation = max(0, incoming.length - maximumEdgeLength)
            + max(0, outgoing.length - maximumEdgeLength)
        let angularViolation = max(0, turnAngle(incoming: incoming, outgoing: outgoing) - maximumTurn)
        return edgeViolation / max(maximumEdgeLength, Float.ulpOfOne) + angularViolation
    }

    private static func rayIntersectionDistance(
        origin: ReferenceVector2,
        direction: ReferenceVector2,
        segment: ReferenceSegmentEndpoints
    ) -> Float? {
        let edge = segment.b - segment.a
        let denominator = direction.cross(edge)
        guard abs(denominator) > 1e-6 else { return nil }
        let offset = segment.a - origin
        let distance = offset.cross(edge) / denominator
        let fraction = offset.cross(direction) / denominator
        guard distance >= 0, fraction >= 0, fraction <= 1 else { return nil }
        return distance
    }

}
