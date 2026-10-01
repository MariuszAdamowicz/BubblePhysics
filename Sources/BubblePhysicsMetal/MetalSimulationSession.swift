import Metal
import BubblePhysics

public enum MetalSessionFailure: Equatable, Sendable {
    case overflow
    case nonFinite
    case commandExecution
}

public enum MetalSessionStatus: Equatable, Sendable {
    case ready
    case failed(MetalSessionFailure)
}

public struct MetalFrameInput: Equatable, Sendable {
    public var gravity: Vector2?
    public var bounds: AABB?
    public var configuration: WorldConfiguration?

    public init(gravity: Vector2? = nil, bounds: AABB? = nil, configuration: WorldConfiguration? = nil) {
        self.gravity = gravity
        self.bounds = bounds
        self.configuration = configuration
    }
}

public struct MetalSessionGrab: Equatable, Sendable {
    public var particleIndex: UInt32
    public var target: SIMD2<Float>

    public init(particleIndex: UInt32, target: SIMD2<Float>) {
        self.particleIndex = particleIndex
        self.target = target
    }
}

public struct MetalFrameResources: @unchecked Sendable {
    public let particleBuffer: MTLBuffer
    public let rangeBuffer: MTLBuffer
    public let particleCount: Int
    public let bubbleCount: Int
    public let pairCountBuffer: MTLBuffer
    public let comparisonCountBuffer: MTLBuffer
}

final class MetalSessionBuffers {
    let particle: MTLBuffer
    let ranges: MTLBuffer
    let distance: MTLBuffer
    let area: MTLBuffer
    let aabb: MTLBuffer
    let keys: MTLBuffer
    let pairs: MTLBuffer
    let pairCount: MTLBuffer
    let comparisons: MTLBuffer
    let neighborCounts: MTLBuffer
    let neighborOffsets: MTLBuffer
    let neighborCursors: MTLBuffer
    let neighbors: MTLBuffer
    let deltas: MTLBuffer
    let particleCapacity: Int
    let bubbleCapacity: Int
    let distanceCapacity: Int
    let areaCapacity: Int
    let pairCapacity: Int
    let sortCapacity: Int

    init?(device: MTLDevice, snapshot: MetalWorldSnapshot) {
        particleCapacity = max(1, snapshot.particles.count)
        bubbleCapacity = max(1, snapshot.bubbleRanges.count)
        distanceCapacity = max(1, snapshot.distanceConstraints.count)
        areaCapacity = max(1, snapshot.areaConstraints.count)
        pairCapacity = max(1, bubbleCapacity * (bubbleCapacity - 1) / 2)
        sortCapacity = Self.nextPowerOfTwo(bubbleCapacity)
        func buffer<T>(_ type: T.Type, _ count: Int) -> MTLBuffer? {
            device.makeBuffer(length: max(1, count) * MemoryLayout<T>.stride, options: .storageModeShared)
        }
        guard let particle = buffer(MetalParticle.self, particleCapacity),
              let ranges = buffer(MetalBubbleRange.self, bubbleCapacity),
              let distance = buffer(MetalDistanceConstraint.self, distanceCapacity),
              let area = buffer(MetalAreaConstraint.self, areaCapacity),
              let aabb = buffer(SIMD4<Float>.self, bubbleCapacity),
              let keys = buffer(SIMD2<UInt32>.self, sortCapacity),
              let pairs = buffer(SIMD2<UInt32>.self, pairCapacity),
              let pairCount = buffer(UInt32.self, 1),
              let comparisons = buffer(UInt32.self, 1),
              let neighborCounts = buffer(UInt32.self, bubbleCapacity),
              let neighborOffsets = buffer(UInt32.self, bubbleCapacity + 1),
              let neighborCursors = buffer(UInt32.self, bubbleCapacity),
              let neighbors = buffer(UInt32.self, pairCapacity * 2),
              let deltas = buffer(SIMD2<Float>.self, particleCapacity)
        else { return nil }
        self.particle = particle; self.ranges = ranges; self.distance = distance; self.area = area
        self.aabb = aabb; self.keys = keys; self.pairs = pairs; self.pairCount = pairCount
        self.comparisons = comparisons; self.neighborCounts = neighborCounts
        self.neighborOffsets = neighborOffsets; self.neighborCursors = neighborCursors
        self.neighbors = neighbors; self.deltas = deltas
    }

    func canHold(_ snapshot: MetalWorldSnapshot) -> Bool {
        snapshot.particles.count <= particleCapacity && snapshot.bubbleRanges.count <= bubbleCapacity &&
        snapshot.distanceConstraints.count <= distanceCapacity && snapshot.areaConstraints.count <= areaCapacity
    }

    func upload(_ snapshot: MetalWorldSnapshot) {
        copy(snapshot.particles, to: particle); copy(snapshot.bubbleRanges, to: ranges)
        copy(snapshot.distanceConstraints, to: distance); copy(snapshot.areaConstraints, to: area)
    }

    private func copy<T>(_ values: [T], to buffer: MTLBuffer) {
        guard !values.isEmpty else { return }
        _ = values.withUnsafeBytes { bytes in memcpy(buffer.contents(), bytes.baseAddress!, bytes.count) }
    }

    private static func nextPowerOfTwo(_ value: Int) -> Int {
        var result = 1
        while result < value { result <<= 1 }
        return result
    }
}

public final class MetalSimulationSession: @unchecked Sendable {
    public private(set) var status: MetalSessionStatus = .ready
    public private(set) var hasActiveGrab = false
    private let solver: MetalBubbleSolver
    private var snapshot: MetalWorldSnapshot
    private var buffers: MetalSessionBuffers
    private var grab: MetalSessionGrab?

    public init(snapshot: MetalWorldSnapshot, device: MTLDevice) throws {
        guard let solver = MetalBubbleSolver(device: device) else { throw MetalSolverError.metalUnavailable }
        guard let buffers = MetalSessionBuffers(device: device, snapshot: snapshot) else { throw MetalSolverError.bufferAllocationFailed }
        self.solver = solver; self.snapshot = snapshot; self.buffers = buffers
        buffers.upload(snapshot)
    }

    internal init(snapshot: MetalWorldSnapshot, solver: MetalBubbleSolver) throws {
        guard let buffers = MetalSessionBuffers(device: solver.device, snapshot: snapshot) else { throw MetalSolverError.bufferAllocationFailed }
        self.solver = solver; self.snapshot = snapshot; self.buffers = buffers
        buffers.upload(snapshot)
    }

    public func encodeFrame(input: MetalFrameInput, commandBuffer: MTLCommandBuffer) throws -> MetalFrameResources {
        guard status == .ready else { throw MetalSolverError.commandExecutionFailed }
        try solver.encodeSessionFrame(snapshot: snapshot, input: input, buffers: buffers, commandBuffer: commandBuffer)
        let encodedBuffers = buffers
        let encodedParticleCount = snapshot.particles.count
        commandBuffer.addCompletedHandler { [weak self] completed in
            guard let self else { return }
            guard completed.status == .completed else {
                self.status = .failed(.commandExecution)
                return
            }
            let pairCount = Int(encodedBuffers.pairCount.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
            if pairCount > encodedBuffers.pairCapacity {
                self.status = .failed(.overflow)
                return
            }
            let particles = encodedBuffers.particle.contents().bindMemory(to: MetalParticle.self, capacity: encodedParticleCount)
            if (0..<encodedParticleCount).contains(where: {
                !particles[$0].position.x.isFinite || !particles[$0].position.y.isFinite ||
                !particles[$0].previousPosition.x.isFinite || !particles[$0].previousPosition.y.isFinite
            }) {
                self.status = .failed(.nonFinite)
            }
        }
        return MetalFrameResources(
            particleBuffer: buffers.particle, rangeBuffer: buffers.ranges,
            particleCount: snapshot.particles.count, bubbleCount: snapshot.bubbleRanges.count,
            pairCountBuffer: buffers.pairCount, comparisonCountBuffer: buffers.comparisons
        )
    }

    public func reset(snapshot: MetalWorldSnapshot) throws {
        if !buffers.canHold(snapshot) {
            guard let replacement = MetalSessionBuffers(device: solver.device, snapshot: snapshot) else { throw MetalSolverError.bufferAllocationFailed }
            buffers = replacement
        }
        self.snapshot = snapshot; buffers.upload(snapshot)
        grab = nil; hasActiveGrab = false; status = .ready
    }

    public func updateGrab(_ grab: MetalSessionGrab?) {
        self.grab = grab; hasActiveGrab = grab != nil
    }

    internal func recordFailureForTesting(_ failure: MetalSessionFailure) { status = .failed(failure) }
}
