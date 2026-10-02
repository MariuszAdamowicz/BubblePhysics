import Foundation

public enum ReferenceContourGenerator {
    public static func points(
        for bubble: ReferenceBubble,
        configuration: ReferenceConfiguration
    ) -> [ReferenceVector2] {
        let maximumLength = configuration.sanitized.maxContourSegmentLength

        let initialSegmentCount = 8
        let fullTurn = Float.pi * 2
        var points: [ReferenceVector2] = []

        for index in 0..<initialSegmentCount {
            let startAngle = fullTurn * Float(index) / Float(initialSegmentCount)
            let endAngle = fullTurn * Float(index + 1) / Float(initialSegmentCount)
            let startPoint = point(on: bubble, angle: startAngle)
            if index == 0 { points.append(startPoint) }
            appendAdaptiveArc(
                bubble: bubble,
                startAngle: startAngle,
                startPoint: startPoint,
                endAngle: endAngle,
                endPoint: point(on: bubble, angle: endAngle),
                maximumLength: maximumLength,
                output: &points
            )
        }

        if points.count > 1 { points.removeLast() }
        return points
    }

    private static func appendAdaptiveArc(
        bubble: ReferenceBubble,
        startAngle: Float,
        startPoint: ReferenceVector2,
        endAngle: Float,
        endPoint: ReferenceVector2,
        maximumLength: Float,
        output: inout [ReferenceVector2]
    ) {
        guard (endPoint - startPoint).length > maximumLength else {
            output.append(endPoint)
            return
        }

        let middleAngle = (startAngle + endAngle) * 0.5
        guard middleAngle > startAngle, middleAngle < endAngle else {
            output.append(endPoint)
            return
        }
        let middlePoint = point(on: bubble, angle: middleAngle)
        appendAdaptiveArc(
            bubble: bubble,
            startAngle: startAngle,
            startPoint: startPoint,
            endAngle: middleAngle,
            endPoint: middlePoint,
            maximumLength: maximumLength,
            output: &output
        )
        appendAdaptiveArc(
            bubble: bubble,
            startAngle: middleAngle,
            startPoint: middlePoint,
            endAngle: endAngle,
            endPoint: endPoint,
            maximumLength: maximumLength,
            output: &output
        )
    }

    private static func point(on bubble: ReferenceBubble, angle: Float) -> ReferenceVector2 {
        let direction = ReferenceVector2(x: cosf(angle), y: sinf(angle))
        return bubble.center + direction * bubble.supportRadius(along: direction)
    }
}
