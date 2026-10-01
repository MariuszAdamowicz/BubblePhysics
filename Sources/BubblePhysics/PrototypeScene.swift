import Foundation

public enum PrototypeSceneSize: Equatable, Sendable {
    case inspection
    case stress
}

public struct KinematicTriangleState: Equatable, Sendable {
    public let position: Vector2
    public let angleRadians: Float
    public let linearVelocity: Vector2
    public let angularVelocity: Float

    public init(position: Vector2, angleRadians: Float, linearVelocity: Vector2, angularVelocity: Float) {
        self.position = position
        self.angleRadians = angleRadians
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
    }
}

public struct KinematicTriangleMotion: Equatable, Sendable {
    public let center: Vector2
    public let radii: Vector2
    public let period: TimeInterval
    public let initialAngleRadians: Float

    public static let `default` = KinematicTriangleMotion(
        center: Vector2(x: 187.5, y: 406),
        radii: Vector2(x: 110, y: 230),
        period: 12,
        initialAngleRadians: 0
    )

    public init(center: Vector2, radii: Vector2, period: TimeInterval, initialAngleRadians: Float) {
        precondition(period > 0)
        self.center = center
        self.radii = radii
        self.period = period
        self.initialAngleRadians = initialAngleRadians
    }

    public func sample(time: TimeInterval, isPaused: Bool) -> KinematicTriangleState {
        let angularSpeed = Float(2 * Double.pi / period)
        let phase = angularSpeed * Float(time)
        let position = Vector2(
            x: center.x + radii.x * cos(phase),
            y: center.y + radii.y * sin(phase)
        )
        let velocity = isPaused ? Vector2.zero : Vector2(
            x: -radii.x * angularSpeed * sin(phase),
            y: radii.y * angularSpeed * cos(phase)
        )
        return KinematicTriangleState(
            position: position,
            angleRadians: initialAngleRadians + phase,
            linearVelocity: velocity,
            angularVelocity: isPaused ? 0 : angularSpeed
        )
    }
}

public enum PrototypeSceneFactory {
    public static let bounds = AABB(minimum: .zero, maximum: Vector2(x: 375, y: 812))

    public static func make(_ size: PrototypeSceneSize) throws -> BubbleWorld {
        var world: BubbleWorld
        switch size {
        case .inspection:
            world = makeInspectionWorld()
        case .stress:
            world = BenchmarkScenario.iPhoneX.makeWorld()
        }
        var triangle = try RigidPolygon.make(
            id: PolygonID(rawValue: 1),
            vertices: [
                Vector2(x: -34, y: 26),
                Vector2(x: 34, y: 26),
                Vector2(x: 0, y: -38)
            ],
            mode: .kinematic
        )
        let state = KinematicTriangleMotion.default.sample(time: 0, isPaused: false)
        triangle.setKinematicTransform(
            position: state.position,
            angleRadians: state.angleRadians,
            linearVelocity: state.linearVelocity,
            angularVelocity: state.angularVelocity
        )
        world.addRigidPolygon(triangle)
        return world
    }

    public static func seeds(for size: PrototypeSceneSize) -> [BenchmarkBubbleSeed] {
        switch size {
        case .inspection:
            let values = BenchmarkScenario.expandedValues([2: 20, 4: 8, 8: 5, 16: 3, 32: 2, 64: 1, 512: 1]).sorted(by: >)
            return values.enumerated().map { index, value in
                if index == 0 {
                    return BenchmarkBubbleSeed(
                        id: BubbleID(rawValue: 1),
                        value: value,
                        center: Vector2(x: 187.5, y: 406),
                        restArea: BenchmarkScenario.restArea(for: value)
                    )
                }
                let packedIndex = index - 1
                let column = packedIndex % 5
                let row = packedIndex / 5
                return BenchmarkBubbleSeed(
                    id: BubbleID(rawValue: index + 1),
                    value: value,
                    center: Vector2(x: 48 + Float(column) * 70 + Float(row % 2) * 8, y: 72 + Float(row) * 104),
                    restArea: BenchmarkScenario.restArea(for: value)
                )
            }
        case .stress:
            return BenchmarkScenario.iPhoneX.seeds
        }
    }

    public static func values(for size: PrototypeSceneSize) -> [Int] {
        seeds(for: size).map(\.value)
    }

    private static func makeInspectionWorld() -> BubbleWorld {
        var world = BubbleWorld(configuration: .default, bounds: bounds)
        for seed in seeds(for: .inspection) {
            let allocated = world.addBubble(center: seed.center, restArea: seed.restArea)
            precondition(allocated == seed.id)
        }
        return world
    }
}
