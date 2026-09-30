import Foundation

public struct BoundaryRemesher: Sendable {
    public let maxSegmentLength: Float
    public let shrinkThreshold: Float

    public init(maxSegmentLength: Float, shrinkThreshold: Float) {
        self.maxSegmentLength = maxSegmentLength
        self.shrinkThreshold = shrinkThreshold
    }

    @discardableResult
    public func refineIfNeeded(_ bubble: inout BubbleTopology) -> Bool {
        for index in bubble.boundaryPoints.indices {
            let next = (index + 1) % bubble.boundaryPoints.count
            let start = bubble.boundaryPoints[index]
            let end = bubble.boundaryPoints[next]
            if distance(from: start, to: end) > maxSegmentLength {
                bubble.boundaryPoints.insert((start + end) * 0.5, at: next)
                return true
            }
        }
        return false
    }

    @discardableResult
    public func coarsenIfNeeded(_ bubble: inout BubbleTopology) -> Bool {
        guard bubble.boundaryPoints.count > 8 else { return false }
        for index in bubble.boundaryPoints.indices {
            let next = (index + 1) % bubble.boundaryPoints.count
            if next != 0 && distance(from: bubble.boundaryPoints[index], to: bubble.boundaryPoints[next]) < shrinkThreshold {
                bubble.boundaryPoints.remove(at: next)
                return true
            }
        }
        return false
    }

    private func distance(from first: Vector2, to second: Vector2) -> Float {
        let delta = second - first
        return sqrt(delta.dot(delta))
    }
}
