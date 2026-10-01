import Foundation

public struct RadialBubbleMaterial: Equatable, Sendable {
    public var radialStiffness: Float
    public var radialNonlinearity: Float
    public var radialDamping: Float
    public var neighborStiffness: Float
    public var pressureResponse: Float
    public var contactCorrection: Float
    public var bodyLinearDrag: Float
    public var bodyAngularDrag: Float
    public var birthDuration: Float
    public var maximumRadialSpeed: Float

    public init(
        radialStiffness: Float,
        radialNonlinearity: Float,
        radialDamping: Float,
        neighborStiffness: Float,
        pressureResponse: Float,
        contactCorrection: Float,
        bodyLinearDrag: Float,
        bodyAngularDrag: Float,
        birthDuration: Float,
        maximumRadialSpeed: Float
    ) {
        precondition(radialStiffness >= 0)
        precondition(radialNonlinearity >= 0)
        precondition(radialDamping >= 0)
        precondition(neighborStiffness >= 0)
        precondition(pressureResponse >= 0)
        precondition(contactCorrection >= 0 && contactCorrection <= 1)
        precondition(bodyLinearDrag >= 0)
        precondition(bodyAngularDrag >= 0)
        precondition(birthDuration > 0)
        precondition(maximumRadialSpeed > 0)
        self.radialStiffness = radialStiffness
        self.radialNonlinearity = radialNonlinearity
        self.radialDamping = radialDamping
        self.neighborStiffness = neighborStiffness
        self.pressureResponse = pressureResponse
        self.contactCorrection = contactCorrection
        self.bodyLinearDrag = bodyLinearDrag
        self.bodyAngularDrag = bodyAngularDrag
        self.birthDuration = birthDuration
        self.maximumRadialSpeed = maximumRadialSpeed
    }

    public static let `default` = RadialBubbleMaterial(
        radialStiffness: 45,
        radialNonlinearity: 0.08,
        radialDamping: 14,
        neighborStiffness: 18,
        pressureResponse: 1,
        contactCorrection: 0.5,
        bodyLinearDrag: 2,
        bodyAngularDrag: 3,
        birthDuration: 0.5,
        maximumRadialSpeed: 100
    )
}

public enum RadialBubbleIntegrator {
    public static func step(
        state: inout RadialBubbleState,
        load: RadialBodyLoad,
        deltaTime: Float
    ) {
        precondition(deltaTime > 0 && deltaTime.isFinite)
        precondition(load.sensorCompression.count == state.sensors.count)
        precondition(load.sensorPressureDeltas.count == state.sensors.count)

        integrateBody(state: &state, load: load, deltaTime: deltaTime)

        let material = state.dynamics
        state.birthProgress = min(1, state.birthProgress + deltaTime / material.birthDuration)
        let progress = state.birthProgress
        let smoothProgress = progress * progress * (3 - 2 * progress)
        let currentTarget = state.targetRadius * smoothProgress
        let previous = state.sensors
        var updated = previous

        for index in previous.indices {
            let priorIndex = (index - 1 + previous.count) % previous.count
            let nextIndex = (index + 1) % previous.count
            let compressedLength = max(
                0,
                previous[index].length - load.sensorCompression[index] * material.contactCorrection
            )
            let extensionValue = currentTarget - compressedLength
            let radialForce = material.radialStiffness * extensionValue
                + material.radialNonlinearity * extensionValue * extensionValue * extensionValue
            let neighborForce = material.neighborStiffness
                * (previous[priorIndex].length + previous[nextIndex].length - 2 * previous[index].length)
            let pressureForce = load.sensorPressureDeltas[index] * material.pressureResponse
            let acceleration = radialForce + neighborForce
                - material.radialDamping * previous[index].radialVelocity
                - pressureForce

            var velocity = previous[index].radialVelocity + acceleration * deltaTime
            velocity = min(material.maximumRadialSpeed, max(-material.maximumRadialSpeed, velocity))
            var length = max(0, compressedLength + velocity * deltaTime)
            if length == 0, velocity < 0 { velocity = 0 }
            if !length.isFinite || !velocity.isFinite {
                length = compressedLength.isFinite ? compressedLength : 0
                velocity = 0
            }

            updated[index].length = length
            updated[index].radialVelocity = velocity
            updated[index].targetLength = currentTarget
            updated[index].pressure = max(0, load.sensorPressureDeltas[index])
        }

        state.sensors = updated
    }

    private static func integrateBody(
        state: inout RadialBubbleState,
        load: RadialBodyLoad,
        deltaTime: Float
    ) {
        let material = state.dynamics
        state.body.linearVelocity = state.body.linearVelocity
            + load.force * (state.body.inverseMass * deltaTime)
        state.body.angularVelocity += load.torque * state.body.inverseMomentOfInertia * deltaTime

        state.body.linearVelocity = state.body.linearVelocity * exp(-material.bodyLinearDrag * deltaTime)
        state.body.angularVelocity *= exp(-material.bodyAngularDrag * deltaTime)
        state.body.center = state.body.center + state.body.linearVelocity * deltaTime
        state.body.angle += state.body.angularVelocity * deltaTime

        if !state.body.center.x.isFinite || !state.body.center.y.isFinite {
            state.body.center = .zero
            state.body.linearVelocity = .zero
        }
        if !state.body.angle.isFinite || !state.body.angularVelocity.isFinite {
            state.body.angle = 0
            state.body.angularVelocity = 0
        }
    }
}
