import Metal
import simd
import BubblePhysics

public struct MetalRadialBody: Equatable, Sendable {
    public var pose: SIMD4<Float>
    public var motion: SIMD4<Float>
    public var target: SIMD4<Float>
    public var padding: SIMD4<Float> = .zero

    public init(_ state: RadialBubbleState) {
        pose = SIMD4(
            state.body.center.x, state.body.center.y,
            state.body.linearVelocity.x, state.body.linearVelocity.y
        )
        motion = SIMD4(
            state.body.angle, state.body.angularVelocity,
            state.body.mass, state.body.momentOfInertia
        )
        target = SIMD4(state.targetRadius, state.birthProgress, state.maxSegmentLength, 0)
    }
}

public struct MetalRadialSensor: Equatable, Sendable {
    public var state: SIMD4<Float>
    public var pressureAndPadding: SIMD4<Float>

    public init(_ sensor: RadialSurfaceSensor) {
        state = SIMD4(sensor.materialAngle, sensor.length, sensor.radialVelocity, sensor.targetLength)
        pressureAndPadding = SIMD4(sensor.pressure, 0, 0, 0)
    }
}

public struct MetalRadialContact: Equatable, Sendable {
    public var indicesAndSourceLow: SIMD4<UInt32>
    public var pointAndNormal: SIMD4<Float>
    public var penetrationBarycentricVelocity: SIMD4<Float>
    public var padding: SIMD4<Float> = .zero

    public init(_ contact: RadialSurfaceContact) {
        indicesAndSourceLow = SIMD4(
            UInt32(contact.sensorStartIndex), UInt32(contact.sensorEndIndex),
            UInt32(truncatingIfNeeded: contact.sourceID), UInt32(truncatingIfNeeded: contact.sourceID >> 32)
        )
        pointAndNormal = SIMD4(contact.point.x, contact.point.y, contact.normal.x, contact.normal.y)
        penetrationBarycentricVelocity = SIMD4(
            contact.penetration, contact.barycentric,
            contact.relativeVelocity.x, contact.relativeVelocity.y
        )
    }
}

struct MetalRadialMaterial: Equatable, Sendable {
    var radial: SIMD4<Float>
    var response: SIMD4<Float>
    var timing: SIMD4<Float>

    init(_ material: RadialBubbleMaterial) {
        radial = SIMD4(
            material.radialStiffness, material.radialNonlinearity,
            material.radialDamping, material.neighborStiffness
        )
        response = SIMD4(
            material.pressureResponse, material.contactCorrection,
            material.bodyLinearDrag, material.bodyAngularDrag
        )
        timing = SIMD4(material.birthDuration, material.maximumRadialSpeed, 0, 0)
    }
}

struct MetalRadialContactMaterial: Equatable, Sendable {
    var values: SIMD4<Float>

    init(_ material: SpringMaterial) {
        values = SIMD4(material.quadraticStiffness, material.quarticStiffness, material.drag, 0)
    }
}

struct MetalRadialStepParameters: Equatable, Sendable {
    var sensorCount: UInt32
    var contactCount: UInt32
    var deltaTime: Float
    var padding: Float = 0
}

public struct MetalRadialFrameResources: @unchecked Sendable {
    public let bodyBuffer: MTLBuffer
    public let sensorBuffer: MTLBuffer
    public let surfacePointBuffer: MTLBuffer
    public let loadHeaderBuffer: MTLBuffer
    public let compressionBuffer: MTLBuffer
    public let pressureBuffer: MTLBuffer
    public let sensorCount: Int

    public func reducedLoad() -> RadialBodyLoad {
        let header = loadHeaderBuffer.contents().bindMemory(to: SIMD4<Float>.self, capacity: 1).pointee
        let compression = compressionBuffer.contents().bindMemory(to: Float.self, capacity: sensorCount)
        let pressure = pressureBuffer.contents().bindMemory(to: Float.self, capacity: sensorCount)
        return RadialBodyLoad(
            force: Vector2(x: header.x, y: header.y),
            torque: header.z,
            sensorCompression: Array(UnsafeBufferPointer(start: compression, count: sensorCount)),
            sensorPressureDeltas: Array(UnsafeBufferPointer(start: pressure, count: sensorCount))
        )
    }
}
