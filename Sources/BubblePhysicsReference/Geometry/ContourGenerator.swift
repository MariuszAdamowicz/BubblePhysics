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
        let fullTurn = 2 * Float.pi
        let directions = (0..<count).map { index in
            let angle = fullTurn * Float(index) / Float(count)
            return ReferenceVector2(x: cosf(angle), y: sinf(angle))
        }

        var limits: [Float] = []
        var dominant: [Int?] = []
        for direction in directions {
            let sample = radialLimit(
                from: bubble.center,
                direction: direction,
                naturalRadius: bubble.targetRadius,
                constraints: constraints,
                finiteSegmentClearance: max(config.positionTolerance, config.contactTolerance * 2)
            )
            limits.append(sample.radius)
            dominant.append(sample.constraintIndex)
        }

        var radii = limits
        for _ in 0..<4 where !constraints.isEmpty {
            let previous = radii
            for index in radii.indices {
                let before = (index + count - 1) % count
                let after = (index + 1) % count
                let isFlatInterior = dominant[index] != nil
                    && dominant[index] == dominant[before]
                    && dominant[index] == dominant[after]
                if isFlatInterior {
                    radii[index] = limits[index]
                    continue
                }
                let pressure = localPressure(
                    indices: [dominant[before], dominant[index], dominant[after]],
                    constraints: constraints
                )
                let smoothing = config.contourSurfaceTension
                    / max(config.contourSurfaceTension + pressure, Float.ulpOfOne)
                let neighborRadius = (previous[before] + 2 * previous[index] + previous[after]) * 0.25
                let proposed = previous[index] + (neighborRadius - previous[index]) * smoothing
                radii[index] = min(limits[index], max(0, proposed))
            }
        }

        return directions.indices.map { index in
            bubble.center + directions[index] * radii[index]
        }
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
                    finiteSegment: .init(a: segment.currentA, b: segment.currentB)
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
        finiteSegmentClearance: Float = 0
    ) -> (radius: Float, constraintIndex: Int?) {
        var radius = naturalRadius
        var limitingIndex: Int?
        for index in constraints.indices {
            let constraint = constraints[index]
            if let segment = constraint.finiteSegment,
               let candidate = rayIntersectionDistance(
                   origin: center, direction: direction, segment: segment
               ), candidate < radius {
                radius = max(0, candidate - finiteSegmentClearance)
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

    private static func localPressure(
        indices: [Int?],
        constraints: [ReferenceContourConstraint]
    ) -> Float {
        indices.compactMap { $0.map { constraints[$0].pressure } }.max() ?? 0
    }
}
