import Foundation

public struct RadialBubbleBody: Equatable, Sendable {
    public var center: Vector2
    public var linearVelocity: Vector2
    public var angle: Float
    public var angularVelocity: Float
    public var mass: Float
    public var momentOfInertia: Float

    public init(
        center: Vector2,
        linearVelocity: Vector2,
        angle: Float,
        angularVelocity: Float,
        mass: Float,
        momentOfInertia: Float
    ) {
        precondition(mass > 0)
        precondition(momentOfInertia > 0)
        self.center = center
        self.linearVelocity = linearVelocity
        self.angle = angle
        self.angularVelocity = angularVelocity
        self.mass = mass
        self.momentOfInertia = momentOfInertia
    }

    public var inverseMass: Float { 1 / mass }
    public var inverseMomentOfInertia: Float { 1 / momentOfInertia }
}

public struct RadialSurfaceSensor: Equatable, Sendable {
    public var materialAngle: Float
    public var length: Float {
        didSet { length = max(0, length) }
    }
    public var radialVelocity: Float
    public var targetLength: Float
    public var pressure: Float

    public init(
        materialAngle: Float,
        length: Float,
        radialVelocity: Float,
        targetLength: Float,
        pressure: Float
    ) {
        self.materialAngle = materialAngle
        self.length = max(0, length)
        self.radialVelocity = radialVelocity
        self.targetLength = max(0, targetLength)
        self.pressure = max(0, pressure)
    }
}

public struct RadialBubbleState: Equatable, Sendable {
    public let id: BubbleID
    public var body: RadialBubbleBody
    public var sensors: [RadialSurfaceSensor]
    public var targetRadius: Float
    public var birthProgress: Float
    public var maxSegmentLength: Float
    public var material: SpringMaterial

    public init(
        id: BubbleID,
        body: RadialBubbleBody,
        sensors: [RadialSurfaceSensor],
        targetRadius: Float,
        birthProgress: Float,
        maxSegmentLength: Float,
        material: SpringMaterial
    ) {
        precondition(!sensors.isEmpty)
        precondition(targetRadius >= 0)
        precondition(maxSegmentLength > 0)
        self.id = id
        self.body = body
        self.sensors = sensors
        self.targetRadius = targetRadius
        self.birthProgress = min(1, max(0, birthProgress))
        self.maxSegmentLength = maxSegmentLength
        self.material = material
    }

    public static func collapsed(
        id: BubbleID,
        center: Vector2,
        targetRadius: Float,
        maxSegmentLength: Float,
        mass: Float
    ) -> RadialBubbleState {
        precondition(targetRadius >= 0)
        precondition(maxSegmentLength > 0)
        precondition(mass > 0)

        let seedCount = 8
        let sensors = (0..<seedCount).map { index in
            RadialSurfaceSensor(
                materialAngle: 2 * .pi * Float(index) / Float(seedCount),
                length: 0,
                radialVelocity: 0,
                targetLength: 0,
                pressure: 0
            )
        }
        let inertiaRadius = max(targetRadius, maxSegmentLength * 0.5)
        return RadialBubbleState(
            id: id,
            body: RadialBubbleBody(
                center: center,
                linearVelocity: .zero,
                angle: 0,
                angularVelocity: 0,
                mass: mass,
                momentOfInertia: 0.5 * mass * inertiaRadius * inertiaRadius
            ),
            sensors: sensors,
            targetRadius: targetRadius,
            birthProgress: 0,
            maxSegmentLength: maxSegmentLength,
            material: .default
        )
    }

    public func surfacePoint(at sensorIndex: Int) -> Vector2 {
        precondition(sensors.indices.contains(sensorIndex))
        let sensor = sensors[sensorIndex]
        let worldAngle = body.angle + sensor.materialAngle
        return body.center + Vector2(x: cos(worldAngle), y: sin(worldAngle)) * sensor.length
    }

    public var surfacePoints: [Vector2] {
        sensors.indices.map(surfacePoint(at:))
    }
}
