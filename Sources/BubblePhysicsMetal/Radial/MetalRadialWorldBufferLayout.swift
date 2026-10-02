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
    var contact: SIMD4<Float>

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
        contact = SIMD4(
            bubble.material.quadraticStiffness, bubble.material.quarticStiffness,
            bubble.material.drag, 0
        )
    }
}

struct MetalRadialPairRecord: Equatable, Sendable {
    var bubblesAndRange: SIMD4<UInt32>
}

struct MetalRadialPairContact: Equatable, Sendable {
    var first: SIMD4<UInt32>
    var second: SIMD4<UInt32>
    var barycentricPenetration: SIMD4<Float>
    var pointNormal: SIMD4<Float>
}

public struct MetalRadialWorldFrameResources: @unchecked Sendable {
    public let bodyBuffer: MTLBuffer
    public let descriptorBuffer: MTLBuffer
    public let sensorBuffer: MTLBuffer
    public let surfacePointBuffer: MTLBuffer
    public let rangeBuffer: MTLBuffer
    public let loadHeaderBuffer: MTLBuffer
    public let compressionBuffer: MTLBuffer
    public let pressureBuffer: MTLBuffer
    public let ranges: [RadialBubbleRange]
    public let bubbleCount: Int
    public let sensorCount: Int
    let contactBuffers: [MTLBuffer]
    let contactCountBuffers: [MTLBuffer]
    let overflowBuffers: [MTLBuffer]
    let pairMetricsBuffer: MTLBuffer?

    public var contactCount: Int {
        contactCountBuffers.reduce(0) {
            $0 + Int($1.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
        }
    }

    public var overflow: Bool {
        overflowBuffers.contains { $0.contents().bindMemory(to: UInt32.self, capacity: 1).pointee != 0 }
            || (pairMetricsBuffer?.contents().bindMemory(to: UInt32.self, capacity: 3)[2] ?? 0) != 0
    }

    public var maximumPenetration: Float {
        zip(contactBuffers, contactCountBuffers).reduce(0) { result, pair in
            let count = Int(pair.1.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
            let contacts = pair.0.contents().bindMemory(to: MetalRadialContact.self, capacity: max(1, count))
            return (0..<count).reduce(result) { max($0, contacts[$1].penetrationBarycentricVelocity.x) }
        }
    }

    public var candidatePairCount: Int {
        guard let pairMetricsBuffer else { return 0 }
        return Int(pairMetricsBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)[0])
    }

    public var pairContactCount: Int {
        guard let pairMetricsBuffer else { return 0 }
        return Int(pairMetricsBuffer.contents().bindMemory(to: UInt32.self, capacity: 2)[1])
    }
}

public enum MetalRadialWorldStatus: Equatable, Sendable {
    case ready
    case failed
}
