import Foundation
import Metal

public struct MetalGrabSelection: Equatable, Sendable {
    public let bubbleID: UInt32
    public let particleIndex: UInt32
}

public final class MetalGrabController: @unchecked Sendable {
    public private(set) var isActive = false
    public private(set) var filteredTarget = SIMD2<Float>.zero
    public let maximumCorrection: Float

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pickPipeline: MTLComputePipelineState
    private let grabPipeline: MTLComputePipelineState
    private let resultBuffer: MTLBuffer
    private let grabBuffer: MTLBuffer
    private let maximumTargetSpeed: Float
    private let targetSmoothing: Float
    private var particleIndex: UInt32?
    private var lastTimestamp: TimeInterval?

    public init(
        device: MTLDevice,
        maximumTargetSpeed: Float = 900,
        targetSmoothing: Float = 0.35,
        maximumCorrection: Float = 1.5
    ) throws {
        guard let library = MetalShaderLibrary.load(
                device: device,
                sourceName: "InteractionKernels",
                requiredFunctions: ["pickBubble", "applyResistantGrab"]
              ),
              let pick = library.makeFunction(name: "pickBubble"),
              let grab = library.makeFunction(name: "applyResistantGrab"),
              let pickPipeline = try? device.makeComputePipelineState(function: pick),
              let grabPipeline = try? device.makeComputePipelineState(function: grab),
              let commandQueue = device.makeCommandQueue(),
              let resultBuffer = device.makeBuffer(length: MemoryLayout<SIMD2<UInt32>>.stride, options: .storageModeShared),
              let grabBuffer = device.makeBuffer(length: MemoryLayout<MetalGrab>.stride, options: .storageModeShared)
        else { throw MetalSolverError.metalUnavailable }
        self.device = device; self.commandQueue = commandQueue
        self.pickPipeline = pickPipeline; self.grabPipeline = grabPipeline
        self.resultBuffer = resultBuffer; self.grabBuffer = grabBuffer
        self.maximumTargetSpeed = maximumTargetSpeed; self.targetSmoothing = targetSmoothing
        self.maximumCorrection = maximumCorrection
    }

    @discardableResult
    public func begin(at point: SIMD2<Float>, resources: MetalFrameResources, timestamp: TimeInterval) async throws -> Bool {
        resultBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: 1).pointee = SIMD2(repeating: UInt32.max)
        guard let commandBuffer = commandQueue.makeCommandBuffer(), let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalSolverError.commandEncodingFailed
        }
        var point = point, count = UInt32(resources.bubbleCount)
        encoder.setComputePipelineState(pickPipeline); encoder.setBuffer(resources.particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(resources.rangeBuffer, offset: 0, index: 1); encoder.setBuffer(resultBuffer, offset: 0, index: 2)
        encoder.setBytes(&point, length: MemoryLayout<SIMD2<Float>>.stride, index: 3); encoder.setBytes(&count, length: 4, index: 4)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)); encoder.endEncoding()
        commandBuffer.commit(); await commandBuffer.completed()
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        let selection = resultBuffer.contents().bindMemory(to: SIMD2<UInt32>.self, capacity: 1).pointee
        guard selection.y != UInt32.max else { end(); return false }
        particleIndex = selection.y; filteredTarget = point; lastTimestamp = timestamp; isActive = true
        return true
    }

    public func move(to target: SIMD2<Float>, timestamp: TimeInterval) {
        guard isActive, let previousTime = lastTimestamp else { return }
        let dt = max(Float(timestamp - previousTime), 0)
        let delta = target - filteredTarget
        let distance = sqrt(delta.x * delta.x + delta.y * delta.y)
        let capped = distance > 0 ? delta / distance * min(distance, maximumTargetSpeed * dt) : .zero
        filteredTarget += capped * min(max(targetSmoothing, 0), 1)
        lastTimestamp = timestamp
    }

    public func end() { particleIndex = nil; lastTimestamp = nil; isActive = false }

    public func encode(into commandBuffer: MTLCommandBuffer, resources: MetalFrameResources) throws {
        guard let particleIndex, isActive else { return }
        grabBuffer.contents().bindMemory(to: MetalGrab.self, capacity: 1).pointee = MetalGrab(
            particleIndex: particleIndex, target: filteredTarget, maximumCorrection: maximumCorrection
        )
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        encoder.setComputePipelineState(grabPipeline); encoder.setBuffer(resources.particleBuffer, offset: 0, index: 0)
        encoder.setBuffer(grabBuffer, offset: 0, index: 1)
        encoder.dispatchThreads(MTLSize(width: 1, height: 1, depth: 1), threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)); encoder.endEncoding()
    }

    internal func installSelectionForTesting(particleIndex: UInt32, target: SIMD2<Float>, timestamp: TimeInterval) {
        self.particleIndex = particleIndex; filteredTarget = target; lastTimestamp = timestamp; isActive = true
    }

    public static func referencePick(at point: SIMD2<Float>, particles: [MetalParticle], ranges: [MetalBubbleRange]) -> MetalGrabSelection? {
        var result: MetalGrabSelection?
        for range in ranges {
            var inside = false, nearestDistance = Float.infinity
            var nearest = range.boundaryStart
            for offset in 0..<Int(range.boundaryCount) {
                let currentIndex = Int(range.boundaryStart) + offset
                let nextIndex = Int(range.boundaryStart) + (offset + 1) % Int(range.boundaryCount)
                let current = particles[currentIndex].position, next = particles[nextIndex].position
                if (current.y > point.y) != (next.y > point.y), point.x < (next.x - current.x) * (point.y - current.y) / (next.y - current.y) + current.x { inside.toggle() }
                let delta = current - point
                let distance = delta.x * delta.x + delta.y * delta.y
                if distance < nearestDistance { nearestDistance = distance; nearest = UInt32(currentIndex) }
            }
            if inside { result = MetalGrabSelection(bubbleID: range.id, particleIndex: nearest) }
        }
        return result
    }
}
