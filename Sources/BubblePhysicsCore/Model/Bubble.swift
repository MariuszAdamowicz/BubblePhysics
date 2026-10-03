import Foundation

public enum BubbleScale {
    public static func radius(forValue value: Double) -> Double {
        guard value > 0, value.isFinite else { return 0 }
        return 22 * sqrt(value / 2)
    }
}

public struct ContourPoint: Equatable, Sendable {
    public var position: BPVector

    public init(position: BPVector) {
        self.position = position
    }
}

public struct Bubble: Equatable, Sendable {
    public var center: BPVector
    public var velocity: BPVector
    public var mass: Double
    public var naturalRadius: Double
    public var contour: [ContourPoint]

    public init(
        center: BPVector,
        velocity: BPVector = .zero,
        mass: Double,
        naturalRadius: Double,
        contour: [ContourPoint]
    ) {
        self.center = center
        self.velocity = velocity
        self.mass = mass
        self.naturalRadius = naturalRadius
        self.contour = contour
    }

    public static func circular(
        center: BPVector,
        naturalRadius: Double,
        mass: Double,
        pointCount: Int
    ) -> Bubble {
        let count = max(3, pointCount)
        let contour = (0..<count).map { index in
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return ContourPoint(position: center + BPVector(
                x: cos(angle) * naturalRadius,
                y: sin(angle) * naturalRadius
            ))
        }
        return Bubble(
            center: center,
            mass: mass,
            naturalRadius: naturalRadius,
            contour: contour
        )
    }
}
