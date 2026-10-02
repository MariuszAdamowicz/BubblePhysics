public struct RadialSegmentIntersection: Equatable, Sendable {
    public let point: Vector2
    public let firstParameter: Float
    public let secondParameter: Float
}

public struct RadialSegmentSeparation: Equatable, Sendable {
    public let firstPoint: Vector2
    public let secondPoint: Vector2
    public let firstParameter: Float
    public let secondParameter: Float
    public let distance: Float
}

public enum RadialSegmentGeometry {
    public static func intersection(
        _ first: (Vector2, Vector2),
        _ second: (Vector2, Vector2)
    ) -> RadialSegmentIntersection? {
        let firstDirection = first.1 - first.0
        let secondDirection = second.1 - second.0
        let denominator = cross(firstDirection, secondDirection)
        guard abs(denominator) > 1e-7 else { return nil }
        let offset = second.0 - first.0
        let firstParameter = cross(offset, secondDirection) / denominator
        let secondParameter = cross(offset, firstDirection) / denominator
        guard firstParameter >= 0, firstParameter <= 1,
              secondParameter >= 0, secondParameter <= 1 else { return nil }
        return RadialSegmentIntersection(
            point: first.0 + firstDirection * firstParameter,
            firstParameter: firstParameter,
            secondParameter: secondParameter
        )
    }

    public static func nearestPoints(
        _ first: (Vector2, Vector2),
        _ second: (Vector2, Vector2)
    ) -> RadialSegmentSeparation {
        if let crossing = intersection(first, second) {
            return RadialSegmentSeparation(
                firstPoint: crossing.point, secondPoint: crossing.point,
                firstParameter: crossing.firstParameter, secondParameter: crossing.secondParameter,
                distance: 0
            )
        }
        return [
            endpointCandidate(point: first.0, parameter: 0, onFirst: true, other: second),
            endpointCandidate(point: first.1, parameter: 1, onFirst: true, other: second),
            endpointCandidate(point: second.0, parameter: 0, onFirst: false, other: first),
            endpointCandidate(point: second.1, parameter: 1, onFirst: false, other: first)
        ].min { $0.distance < $1.distance }!
    }

    public static func contains(_ point: Vector2, contour: [Vector2]) -> Bool {
        guard contour.count >= 3 else { return false }
        var inside = false
        var previous = contour[contour.count - 1]
        for current in contour {
            if (current.y > point.y) != (previous.y > point.y) {
                let x = (previous.x - current.x) * (point.y - current.y)
                    / (previous.y - current.y) + current.x
                if point.x < x { inside.toggle() }
            }
            previous = current
        }
        return inside
    }

    private static func endpointCandidate(
        point: Vector2, parameter: Float, onFirst: Bool, other: (Vector2, Vector2)
    ) -> RadialSegmentSeparation {
        let projection = project(point, onto: other)
        let delta = projection.point - point
        return RadialSegmentSeparation(
            firstPoint: onFirst ? point : projection.point,
            secondPoint: onFirst ? projection.point : point,
            firstParameter: onFirst ? parameter : projection.parameter,
            secondParameter: onFirst ? projection.parameter : parameter,
            distance: delta.dot(delta).squareRoot()
        )
    }

    private static func project(
        _ point: Vector2, onto segment: (Vector2, Vector2)
    ) -> (point: Vector2, parameter: Float) {
        let direction = segment.1 - segment.0
        let lengthSquared = direction.dot(direction)
        let parameter = lengthSquared > 1e-12
            ? min(1, max(0, (point - segment.0).dot(direction) / lengthSquared)) : 0
        return (segment.0 + direction * parameter, parameter)
    }

    private static func cross(_ left: Vector2, _ right: Vector2) -> Float {
        left.x * right.y - left.y * right.x
    }
}
