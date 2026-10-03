import Foundation

public enum ReferenceContourGenerator {
    public static func points(
        for bubble: ReferenceBubble,
        contacts: [ReferenceContact],
        configuration: ReferenceConfiguration
    ) -> [ReferenceVector2] {
        let config = configuration.sanitized
        let circumference = 2 * Float.pi * bubble.targetRadius
        let count = max(32, Int(ceilf(circumference / config.maxContourSegmentLength)))
        let constraints = contourConstraints(for: bubble, contacts: contacts)
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
                constraints: constraints
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
        contacts: [ReferenceContact]
    ) -> [ReferenceContourConstraint] {
        contacts.compactMap { contact in
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
        constraints: [ReferenceContourConstraint]
    ) -> (radius: Float, constraintIndex: Int?) {
        var radius = naturalRadius
        var limitingIndex: Int?
        for index in constraints.indices {
            let constraint = constraints[index]
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

    private static func localPressure(
        indices: [Int?],
        constraints: [ReferenceContourConstraint]
    ) -> Float {
        indices.compactMap { $0.map { constraints[$0].pressure } }.max() ?? 0
    }
}
