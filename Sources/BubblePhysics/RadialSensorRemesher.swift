import Foundation

public enum RadialSensorRemesher {
    public static func requiredCount(
        for state: RadialBubbleState,
        maxSegmentLength: Float
    ) -> Int {
        precondition(maxSegmentLength > 0 && maxSegmentLength.isFinite)
        let points = state.surfacePoints
        let perimeter = points.indices.reduce(Float.zero) { partial, index in
            let edge = points[(index + 1) % points.count] - points[index]
            return partial + edge.dot(edge).squareRoot()
        }
        guard perimeter.isFinite else { return state.sensors.count }
        return max(8, Int(ceil(perimeter / maxSegmentLength)))
    }

    public static func resample(
        _ state: RadialBubbleState,
        to count: Int
    ) -> RadialBubbleState {
        precondition(count >= 8)
        guard count != state.sensors.count else { return state }

        let ordered = state.sensors.sorted { normalizedAngle($0.materialAngle) < normalizedAngle($1.materialAngle) }
        var sensors: [RadialSurfaceSensor] = []
        sensors.reserveCapacity(count)
        for index in 0..<count {
            let angle = 2 * Float.pi * Float(index) / Float(count)
            sensors.append(interpolate(ordered, at: angle))
        }

        preserveMean(ordered.map(\.length), in: &sensors, keyPath: \RadialSurfaceSensor.length)
        preserveMean(ordered.map(\.radialVelocity), in: &sensors, keyPath: \RadialSurfaceSensor.radialVelocity)
        preserveMean(ordered.map(\.targetLength), in: &sensors, keyPath: \RadialSurfaceSensor.targetLength)
        preserveMean(ordered.map(\.pressure), in: &sensors, keyPath: \RadialSurfaceSensor.pressure)

        var result = state
        result.sensors = sensors
        return result
    }

    private static func interpolate(
        _ sensors: [RadialSurfaceSensor],
        at angle: Float
    ) -> RadialSurfaceSensor {
        let upperIndex = sensors.firstIndex { normalizedAngle($0.materialAngle) > angle } ?? 0
        let lowerIndex = (upperIndex - 1 + sensors.count) % sensors.count
        let lower = sensors[lowerIndex]
        let upper = sensors[upperIndex]
        var lowerAngle = normalizedAngle(lower.materialAngle)
        var upperAngle = normalizedAngle(upper.materialAngle)
        var queryAngle = angle
        if upperIndex == 0 {
            upperAngle += 2 * .pi
            if queryAngle < lowerAngle { queryAngle += 2 * .pi }
        }
        if lowerAngle > queryAngle { lowerAngle -= 2 * .pi }
        let span = upperAngle - lowerAngle
        let fraction = span > 1e-7 ? (queryAngle - lowerAngle) / span : 0

        return RadialSurfaceSensor(
            materialAngle: angle,
            length: lerp(lower.length, upper.length, fraction),
            radialVelocity: lerp(lower.radialVelocity, upper.radialVelocity, fraction),
            targetLength: lerp(lower.targetLength, upper.targetLength, fraction),
            pressure: lerp(lower.pressure, upper.pressure, fraction)
        )
    }

    private static func preserveMean(
        _ original: [Float],
        in sensors: inout [RadialSurfaceSensor],
        keyPath: WritableKeyPath<RadialSurfaceSensor, Float>
    ) {
        let originalMean = original.reduce(0, +) / Float(original.count)
        let newMean = sensors.reduce(0) { $0 + $1[keyPath: keyPath] } / Float(sensors.count)
        let correction = originalMean - newMean
        for index in sensors.indices {
            sensors[index][keyPath: keyPath] += correction
        }
    }

    private static func lerp(_ start: Float, _ end: Float, _ fraction: Float) -> Float {
        start + (end - start) * fraction
    }

    private static func normalizedAngle(_ angle: Float) -> Float {
        let fullTurn = 2 * Float.pi
        let remainder = angle.truncatingRemainder(dividingBy: fullTurn)
        return remainder >= 0 ? remainder : remainder + fullTurn
    }
}
