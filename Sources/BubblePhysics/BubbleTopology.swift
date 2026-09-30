import Foundation

public struct BubbleTopology: Sendable {
    public let id: BubbleID
    public var center: Vector2
    public let restArea: Float
    public var boundaryPoints: [Vector2]

    public static func regular(id: BubbleID, center: Vector2, restArea: Float, maxBoundarySegmentLength: Float) -> BubbleTopology {
        precondition(restArea > 0 && maxBoundarySegmentLength > 0)
        let radius = sqrt(restArea / .pi)
        let count = max(8, Int(ceil(2 * .pi * radius / maxBoundarySegmentLength)))
        let points = (0..<count).map { index -> Vector2 in
            let angle = Float(index) * 2 * .pi / Float(count)
            return center + Vector2(x: cos(angle) * radius, y: sin(angle) * radius)
        }
        return BubbleTopology(id: id, center: center, restArea: restArea, boundaryPoints: points)
    }

    public var pose: BubblePose {
        let vector = boundaryPoints[0] - center
        let length = sqrt(vector.dot(vector))
        let axis = length > 0 ? vector * (1 / length) : Vector2(x: 1, y: 0)
        return BubblePose(center: center, boundaryPoints: boundaryPoints, materialAxis: axis)
    }
}
