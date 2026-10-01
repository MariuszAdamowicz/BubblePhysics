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
    public var triangleState: KinematicTriangleState?

    public init(gravity: Vector2? = nil, bounds: AABB? = nil, configuration: WorldConfiguration? = nil, triangleState: KinematicTriangleState? = nil) {
        self.gravity = gravity
        self.bounds = bounds
        self.configuration = configuration
        self.triangleState = triangleState
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
    public let contourContactCountBuffer: MTLBuffer
    public let contourContactOverflowBuffer: MTLBuffer
    public let polygonVertexBuffer: MTLBuffer
    public let polygonVertexCount: Int
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
    let polygonVertices: MTLBuffer
    let polygons: MTLBuffer
    let contourContacts: MTLBuffer
    let contourContactCounts: MTLBuffer
    let contourContactOffsets: MTLBuffer
    let contourContactTotal: MTLBuffer
    let contourContactOverflow: MTLBuffer
    let contourCorrections: MTLBuffer
    let contourDispatchArguments: MTLBuffer
    let contourPairContactFlags: MTLBuffer
    let polygonVertexCount: Int
    let polygonCount: Int
    let particleCapacity: Int
    let bubbleCapacity: Int
    let distanceCapacity: Int
    let areaCapacity: Int
    let pairCapacity: Int
    let sortCapacity: Int
    let contourContactCapacity: Int
    let maximumBoundaryCount: Int

    init?(device: MTLDevice, snapshot: MetalWorldSnapshot, minimumContourContactCapacity: Int = 0) {
        particleCapacity = max(1, snapshot.particles.count)
        bubbleCapacity = max(1, snapshot.bubbleRanges.count)
        distanceCapacity = max(1, snapshot.springConstraints.count)
        areaCapacity = max(1, snapshot.areaConstraints.count)
        pairCapacity = max(1, bubbleCapacity * (bubbleCapacity - 1) / 2)
        sortCapacity = Self.nextPowerOfTwo(bubbleCapacity)
        contourContactCapacity = max(1, snapshot.particles.count * 8, minimumContourContactCapacity)
        maximumBoundaryCount = max(1, snapshot.bubbleRanges.map { Int($0.boundaryCount) }.max() ?? 1)
        func buffer<T>(_ type: T.Type, _ count: Int) -> MTLBuffer? {
            device.makeBuffer(length: max(1, count) * MemoryLayout<T>.stride, options: .storageModeShared)
        }
        guard let particle = buffer(MetalParticle.self, particleCapacity),
              let ranges = buffer(MetalBubbleRange.self, bubbleCapacity),
              let distance = buffer(MetalSpringConstraint.self, distanceCapacity),
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
              , let polygonVertices = buffer(SIMD2<Float>.self, max(1, snapshot.polygons.reduce(0) { $0 + $1.worldVertices.count }))
              , let polygons = buffer(MetalInteractionPolygon.self, max(1, snapshot.polygons.count))
              , let contourContacts = buffer(MetalContourContact.self, contourContactCapacity)
              , let contourContactCounts = buffer(UInt32.self, pairCapacity * 3)
              , let contourContactOffsets = buffer(UInt32.self, pairCapacity * 3 + 1)
              , let contourContactTotal = buffer(UInt32.self, 1)
              , let contourContactOverflow = buffer(UInt32.self, 1)
              , let contourCorrections = buffer(SIMD4<Int32>.self, particleCapacity)
              , let contourDispatchArguments = device.makeBuffer(length: 3 * MemoryLayout<UInt32>.stride, options: .storageModeShared)
              , let contourPairContactFlags = buffer(UInt32.self, pairCapacity)
        else { return nil }
        self.particle = particle; self.ranges = ranges; self.distance = distance; self.area = area
        self.aabb = aabb; self.keys = keys; self.pairs = pairs; self.pairCount = pairCount
        self.comparisons = comparisons; self.neighborCounts = neighborCounts
        self.neighborOffsets = neighborOffsets; self.neighborCursors = neighborCursors
        self.neighbors = neighbors; self.deltas = deltas
        self.polygonVertices = polygonVertices; self.polygons = polygons
        self.contourContacts = contourContacts; self.contourContactCounts = contourContactCounts
        self.contourContactOffsets = contourContactOffsets; self.contourContactTotal = contourContactTotal
        self.contourContactOverflow = contourContactOverflow
        self.contourCorrections = contourCorrections
        self.contourDispatchArguments = contourDispatchArguments
        self.contourPairContactFlags = contourPairContactFlags
        polygonVertexCount = snapshot.polygons.reduce(0) { $0 + $1.worldVertices.count }; polygonCount = snapshot.polygons.count
        contourContactTotal.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        contourContactOverflow.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
    }

    func canHold(_ snapshot: MetalWorldSnapshot) -> Bool {
        snapshot.particles.count <= particleCapacity && snapshot.bubbleRanges.count <= bubbleCapacity &&
        snapshot.springConstraints.count <= distanceCapacity && snapshot.areaConstraints.count <= areaCapacity &&
        (snapshot.bubbleRanges.map { Int($0.boundaryCount) }.max() ?? 0) <= maximumBoundaryCount
    }

    func upload(_ snapshot: MetalWorldSnapshot) {
        copy(snapshot.particles, to: particle); copy(snapshot.bubbleRanges, to: ranges)
        copy(snapshot.springConstraints, to: distance); copy(snapshot.areaConstraints, to: area)
        var vertices: [SIMD2<Float>] = [], records: [MetalInteractionPolygon] = []
        for polygon in snapshot.polygons {
            let start = vertices.count; vertices.append(contentsOf: polygon.worldVertices.map { SIMD2($0.x, $0.y) })
            records.append(.init(vertexStart: UInt32(start), vertexCount: UInt32(polygon.worldVertices.count), position: SIMD2(polygon.position.x, polygon.position.y), linearVelocity: SIMD2(polygon.linearVelocity.x, polygon.linearVelocity.y), angularVelocity: polygon.angularVelocity))
        }
        copy(vertices, to: polygonVertices); copy(records, to: polygons)
    }

    func updateTriangle(_ state: KinematicTriangleState, snapshot: MetalWorldSnapshot) {
        guard let original = snapshot.polygons.first else { return }
        let c = cos(state.angleRadians), s = sin(state.angleRadians)
        let vertices = original.worldVertices.map { point -> SIMD2<Float> in
            let local = SIMD2(point.x - original.position.x, point.y - original.position.y)
            return SIMD2(state.position.x + local.x * c - local.y * s, state.position.y + local.x * s + local.y * c)
        }
        copy(vertices, to: polygonVertices)
        let record = MetalInteractionPolygon(vertexStart: 0, vertexCount: UInt32(vertices.count), position: SIMD2(state.position.x, state.position.y), linearVelocity: SIMD2(state.linearVelocity.x, state.linearVelocity.y), angularVelocity: state.angularVelocity)
        copy([record], to: polygons)
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
    private let grabController: MetalGrabController
    private var snapshot: MetalWorldSnapshot
    private var buffers: MetalSessionBuffers
    private var grab: MetalSessionGrab?
    private var remeshTransaction: MetalRemeshTransaction?

    public init(snapshot: MetalWorldSnapshot, device: MTLDevice) throws {
        guard let solver = MetalBubbleSolver(device: device) else { throw MetalSolverError.metalUnavailable }
        guard let buffers = MetalSessionBuffers(device: device, snapshot: snapshot) else { throw MetalSolverError.bufferAllocationFailed }
        self.solver = solver; self.grabController = try MetalGrabController(device: device); self.snapshot = snapshot; self.buffers = buffers
        buffers.upload(snapshot)
    }

    internal init(snapshot: MetalWorldSnapshot, solver: MetalBubbleSolver) throws {
        guard let buffers = MetalSessionBuffers(device: solver.device, snapshot: snapshot) else { throw MetalSolverError.bufferAllocationFailed }
        self.solver = solver; self.grabController = try MetalGrabController(device: solver.device); self.snapshot = snapshot; self.buffers = buffers
        buffers.upload(snapshot)
    }

    public func encodeFrame(input: MetalFrameInput, commandBuffer: MTLCommandBuffer) throws -> MetalFrameResources {
        guard status == .ready else { throw MetalSolverError.commandExecutionFailed }
        let resources = frameResources()
        if let triangleState = input.triangleState { buffers.updateTriangle(triangleState, snapshot: snapshot) }
        try grabController.encode(into: commandBuffer, resources: resources)
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
            let contourOverflow = encodedBuffers.contourContactOverflow.contents().bindMemory(to: UInt32.self, capacity: 1).pointee
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
                return
            }
            if contourOverflow != 0 {
                let required = Int(encodedBuffers.contourContactTotal.contents().bindMemory(to: UInt32.self, capacity: 1).pointee)
                let preserved = self.snapshot.replacingParticles(Array(UnsafeBufferPointer(start: particles, count: encodedParticleCount)))
                let capacity = max(required, encodedBuffers.contourContactCapacity * 2)
                guard let replacement = MetalSessionBuffers(
                    device: self.solver.device,
                    snapshot: preserved,
                    minimumContourContactCapacity: capacity
                ) else {
                    self.status = .failed(.overflow)
                    return
                }
                self.snapshot = preserved
                self.buffers = replacement
                replacement.upload(preserved)
            }
        }
        return resources
    }

    public func reset(snapshot: MetalWorldSnapshot) throws {
        if !buffers.canHold(snapshot) {
            guard let replacement = MetalSessionBuffers(device: solver.device, snapshot: snapshot) else { throw MetalSolverError.bufferAllocationFailed }
            buffers = replacement
        }
        self.snapshot = snapshot; buffers.upload(snapshot)
        grab = nil; grabController.end(); hasActiveGrab = false; status = .ready
    }

    public func scheduleRemesh(_ contour: AdaptiveContour, policy: RemeshPolicy, capacity: Int) throws -> MetalRemeshResult {
        let transaction = try MetalRemeshTransaction(initialCapacity: capacity, device: solver.device)
        remeshTransaction = transaction
        return try transaction.apply(contour, policy: policy)
    }

    public func applyPendingRemeshAtFrameBoundary() throws -> MetalRemeshResult {
        guard let remeshTransaction else { throw MetalSolverError.invalidTopologyCommand }
        return try remeshTransaction.applyPendingAtFrameBoundary()
    }

    public func updateGrab(_ grab: MetalSessionGrab?) {
        self.grab = grab; hasActiveGrab = grab != nil
        if let grab {
            grabController.installSelectionForTesting(
                particleIndex: grab.particleIndex,
                target: grab.target,
                timestamp: ProcessInfo.processInfo.systemUptime
            )
        } else {
            grabController.end()
        }
    }

    @discardableResult
    public func beginGrab(at point: SIMD2<Float>, resources: MetalFrameResources, timestamp: TimeInterval) async throws -> Bool {
        let selected = try await grabController.begin(at: point, resources: resources, timestamp: timestamp)
        hasActiveGrab = selected
        return selected
    }

    public func moveGrab(to point: SIMD2<Float>, timestamp: TimeInterval) { grabController.move(to: point, timestamp: timestamp) }
    public func endGrab() { grabController.end(); hasActiveGrab = false }

    private func frameResources() -> MetalFrameResources {
        MetalFrameResources(
            particleBuffer: buffers.particle, rangeBuffer: buffers.ranges,
            particleCount: snapshot.particles.count, bubbleCount: snapshot.bubbleRanges.count,
            pairCountBuffer: buffers.pairCount, comparisonCountBuffer: buffers.comparisons,
            contourContactCountBuffer: buffers.contourContactTotal,
            contourContactOverflowBuffer: buffers.contourContactOverflow,
            polygonVertexBuffer: buffers.polygonVertices, polygonVertexCount: buffers.polygonVertexCount
        )
    }

    internal func recordFailureForTesting(_ failure: MetalSessionFailure) { status = .failed(failure) }
}
