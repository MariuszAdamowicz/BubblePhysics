import Metal
import simd
import BubblePhysics

public protocol MetalBufferAllocator: Sendable {
    func makeBuffer(device: MTLDevice, length: Int, options: MTLResourceOptions) -> MTLBuffer?
}

public struct DefaultMetalBufferAllocator: MetalBufferAllocator {
    public init() {}
    public func makeBuffer(device: MTLDevice, length: Int, options: MTLResourceOptions) -> MTLBuffer? {
        device.makeBuffer(length: max(1, length), options: options)
    }
}

struct MetalRadialWorldDescriptor: Equatable, Sendable {
    var range: SIMD4<UInt32>
    var radial: SIMD4<Float>
    var response: SIMD4<Float>
    var timing: SIMD4<Float>

    init(bubble: RadialBubbleState, range: RadialBubbleRange) {
        self.range = SIMD4(UInt32(range.sensorStart), UInt32(range.sensorCount), UInt32(range.bubbleIndex), 0)
        radial = SIMD4(
            bubble.dynamics.radialStiffness, bubble.dynamics.radialNonlinearity,
            bubble.dynamics.radialDamping, bubble.dynamics.neighborStiffness
        )
        response = SIMD4(
            bubble.dynamics.pressureResponse, bubble.dynamics.contactCorrection,
            bubble.dynamics.bodyLinearDrag, bubble.dynamics.bodyAngularDrag
        )
        timing = SIMD4(bubble.dynamics.birthDuration, bubble.dynamics.maximumRadialSpeed, 0, 0)
    }
}

public struct MetalRadialWorldFrameResources: @unchecked Sendable {
    public let bodyBuffer: MTLBuffer
    public let descriptorBuffer: MTLBuffer
    public let sensorBuffer: MTLBuffer
    public let surfacePointBuffer: MTLBuffer
    public let rangeBuffer: MTLBuffer
    public let ranges: [RadialBubbleRange]
    public let bubbleCount: Int
    public let sensorCount: Int
}

public enum MetalRadialWorldStatus: Equatable, Sendable {
    case ready
    case failed
}
