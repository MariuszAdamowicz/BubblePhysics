import Foundation

public struct RadialSurfaceContact: Equatable, Sendable {
    public let sensorStartIndex: Int
    public let sensorEndIndex: Int
    public let barycentric: Float
    public let point: Vector2
    public let normal: Vector2
    public let penetration: Float
    public let relativeVelocity: Vector2
    public let sourceID: UInt64

    public init(
        sensorStartIndex: Int,
        sensorEndIndex: Int,
        barycentric: Float,
        point: Vector2,
        normal: Vector2,
        penetration: Float,
        relativeVelocity: Vector2,
        sourceID: UInt64
    ) {
        self.sensorStartIndex = sensorStartIndex
        self.sensorEndIndex = sensorEndIndex
        self.barycentric = min(1, max(0, barycentric))
        self.point = point
        self.normal = normal
        self.penetration = max(0, penetration)
        self.relativeVelocity = relativeVelocity
        self.sourceID = sourceID
    }
}

public struct RadialBodyLoad: Equatable, Sendable {
    public var force: Vector2
    public var torque: Float
    public var sensorCompression: [Float]
    public var sensorPressureDeltas: [Float]

    public init(
        force: Vector2,
        torque: Float,
        sensorCompression: [Float],
        sensorPressureDeltas: [Float]
    ) {
        precondition(sensorCompression.count == sensorPressureDeltas.count)
        self.force = force
        self.torque = torque
        self.sensorCompression = sensorCompression
        self.sensorPressureDeltas = sensorPressureDeltas
    }

    public static func zero(sensorCount: Int) -> RadialBodyLoad {
        RadialBodyLoad(
            force: .zero,
            torque: 0,
            sensorCompression: Array(repeating: 0, count: sensorCount),
            sensorPressureDeltas: Array(repeating: 0, count: sensorCount)
        )
    }
}

public enum RadialContactResponse {
    public static func reduce(
        contacts: [RadialSurfaceContact],
        for bubble: RadialBubbleState
    ) -> RadialBodyLoad {
        var result = RadialBodyLoad.zero(sensorCount: bubble.sensors.count)
        let ordered = contacts.sorted(by: stableOrder)

        for contact in ordered {
            guard
                result.sensorCompression.indices.contains(contact.sensorStartIndex),
                result.sensorCompression.indices.contains(contact.sensorEndIndex),
                contact.penetration.isFinite
            else { continue }

            let normalSquared = contact.normal.dot(contact.normal)
            guard normalSquared > 1e-12, normalSquared.isFinite else { continue }
            let normal = contact.normal * (1 / normalSquared.squareRoot())
            let closingSpeed = max(0, -contact.relativeVelocity.dot(normal))
            let elasticForce = bubble.material.springForce(extension: contact.penetration)
            let dampingForce = closingSpeed * bubble.material.drag * bubble.body.mass
            let magnitude = max(0, elasticForce + dampingForce)
            guard magnitude.isFinite else { continue }

            let startWeight = 1 - contact.barycentric
            let endWeight = contact.barycentric
            result.sensorCompression[contact.sensorStartIndex] += contact.penetration * startWeight
            result.sensorCompression[contact.sensorEndIndex] += contact.penetration * endWeight
            result.sensorPressureDeltas[contact.sensorStartIndex] += magnitude * startWeight
            result.sensorPressureDeltas[contact.sensorEndIndex] += magnitude * endWeight

            let contactForce = normal * magnitude
            result.force = result.force + contactForce
            result.torque += cross(contact.point - bubble.body.center, contactForce)
        }

        return result
    }

    private static func stableOrder(_ left: RadialSurfaceContact, _ right: RadialSurfaceContact) -> Bool {
        if left.sourceID != right.sourceID { return left.sourceID < right.sourceID }
        if left.sensorStartIndex != right.sensorStartIndex { return left.sensorStartIndex < right.sensorStartIndex }
        if left.sensorEndIndex != right.sensorEndIndex { return left.sensorEndIndex < right.sensorEndIndex }
        return left.barycentric < right.barycentric
    }

    private static func cross(_ left: Vector2, _ right: Vector2) -> Float {
        left.x * right.y - left.y * right.x
    }
}
