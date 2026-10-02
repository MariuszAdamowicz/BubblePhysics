import Metal
import BubblePhysics

public struct MetalRadialWorldStep: Sendable {
    public let polygons: [SimulationPolygonSnapshot]
    public let deltaTime: Float

    public init(polygons: [SimulationPolygonSnapshot], deltaTime: Float) {
        precondition(deltaTime > 0 && deltaTime.isFinite)
        self.polygons = polygons
        self.deltaTime = deltaTime
    }
}

public final class MetalRadialWorldSimulation: @unchecked Sendable {
    private let device: MTLDevice
    private let allocator: any MetalBufferAllocator
    private let pipeline: MTLComputePipelineState
    private let environmentPipeline: MTLComputePipelineState
    private let reducePipeline: MTLComputePipelineState
    private let generatePairPipeline: MTLComputePipelineState
    private let reducePairPipeline: MTLComputePipelineState
    private let environmentContactCapacity: Int?
    private var sensorBufferA: MTLBuffer
    private var sensorBufferB: MTLBuffer
    private var currentIsA = true
    private var templateWorld: RadialWorldState
    public private(set) var resources: MetalRadialWorldFrameResources
    public private(set) var status: MetalRadialWorldStatus = .ready

    public init(
        device: MTLDevice,
        world: RadialWorldState,
        allocator: any MetalBufferAllocator = DefaultMetalBufferAllocator(),
        environmentContactCapacity: Int? = nil
    ) throws {
        guard let library = MetalShaderLibrary.load(
            device: device, sourceName: "RadialWorldKernels",
            requiredFunctions: ["radialWorldFreeStep"]
        ), let function = library.makeFunction(name: "radialWorldFreeStep") else {
            throw MetalSolverError.metalUnavailable
        }
        self.device = device
        self.allocator = allocator
        pipeline = try device.makeComputePipelineState(function: function)
        guard let contactLibrary = MetalShaderLibrary.load(
            device: device, sourceName: "RadialContactKernels",
            requiredFunctions: ["radialGenerateEnvironmentContacts"]
        ), let environmentFunction = contactLibrary.makeFunction(name: "radialGenerateEnvironmentContacts"),
        let bubbleLibrary = MetalShaderLibrary.load(
            device: device, sourceName: "RadialBubbleKernels",
            requiredFunctions: ["radialReduceContacts"]
        ), let reduceFunction = bubbleLibrary.makeFunction(name: "radialReduceContacts") else {
            throw MetalSolverError.metalUnavailable
        }
        environmentPipeline = try device.makeComputePipelineState(function: environmentFunction)
        reducePipeline = try device.makeComputePipelineState(function: reduceFunction)
        guard let pairLibrary = MetalShaderLibrary.load(
            device: device, sourceName: "RadialWorldPairKernels",
            requiredFunctions: ["radialWorldGeneratePairContacts", "radialWorldReducePairContacts"]
        ), let generatePairFunction = pairLibrary.makeFunction(name: "radialWorldGeneratePairContacts"),
           let reducePairFunction = pairLibrary.makeFunction(name: "radialWorldReducePairContacts") else {
            throw MetalSolverError.metalUnavailable
        }
        generatePairPipeline = try device.makeComputePipelineState(function: generatePairFunction)
        reducePairPipeline = try device.makeComputePipelineState(function: reducePairFunction)
        self.environmentContactCapacity = environmentContactCapacity
        templateWorld = world
        let packed = try Self.allocate(device: device, allocator: allocator, world: world)
        resources = packed.resources
        sensorBufferA = packed.sensorA
        sensorBufferB = packed.sensorB
    }

    public var world: RadialWorldState { unpackWorld() }

    public func setTargetRadius(_ radius: Float, for id: BubbleID, restartBirth: Bool = true) {
        guard radius >= 0, let index = templateWorld.bubbles.firstIndex(where: { $0.id == id }) else { return }
        let bodies = resources.bodyBuffer.contents().bindMemory(
            to: MetalRadialBody.self, capacity: resources.bubbleCount
        )
        bodies[index].target.x = radius
        if restartBirth { bodies[index].target.y = 0 }
        var bubbles = templateWorld.bubbles
        bubbles[index].targetRadius = radius
        if restartBirth { bubbles[index].birthProgress = 0 }
        templateWorld = try! RadialWorldState(bubbles: bubbles)
    }

    public func encodeFreeStep(
        deltaTime: Float,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialWorldFrameResources {
        guard status == .ready else { throw MetalSolverError.commandExecutionFailed }
        memset(resources.loadHeaderBuffer.contents(), 0, resources.bubbleCount * MemoryLayout<SIMD4<Float>>.stride)
        memset(resources.compressionBuffer.contents(), 0, resources.sensorCount * MemoryLayout<Float>.stride)
        memset(resources.pressureBuffer.contents(), 0, resources.sensorCount * MemoryLayout<Float>.stride)
        return try encodeIntegration(
            deltaTime: deltaTime, commandBuffer: commandBuffer,
            sourceSensorBuffer: currentSensorBuffer,
            destinationSensorBuffer: destinationSensorBuffer
        )
    }

    private func encodeIntegration(
        deltaTime: Float,
        commandBuffer: MTLCommandBuffer,
        contactBuffers: [MTLBuffer] = [],
        countBuffers: [MTLBuffer] = [],
        overflowBuffers: [MTLBuffer] = [],
        pairMetricsBuffer: MTLBuffer? = nil,
        sourceSensorBuffer: MTLBuffer,
        destinationSensorBuffer: MTLBuffer
    ) throws -> MetalRadialWorldFrameResources {
        var parameters = SIMD4<UInt32>(
            UInt32(resources.bubbleCount), UInt32(resources.sensorCount),
            deltaTime.bitPattern, 0
        )
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalSolverError.commandEncodingFailed
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(resources.bodyBuffer, offset: 0, index: 0)
        encoder.setBuffer(resources.descriptorBuffer, offset: 0, index: 1)
        encoder.setBuffer(sourceSensorBuffer, offset: 0, index: 2)
        encoder.setBuffer(destinationSensorBuffer, offset: 0, index: 3)
        encoder.setBuffer(resources.surfacePointBuffer, offset: 0, index: 4)
        encoder.setBuffer(resources.loadHeaderBuffer, offset: 0, index: 5)
        encoder.setBuffer(resources.compressionBuffer, offset: 0, index: 6)
        encoder.setBuffer(resources.pressureBuffer, offset: 0, index: 7)
        encoder.setBytes(&parameters, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 8)
        let width = max(1, min(pipeline.threadExecutionWidth, resources.bubbleCount))
        encoder.dispatchThreads(
            MTLSize(width: resources.bubbleCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        return frameResources(
            sensorBuffer: destinationSensorBuffer,
            contactBuffers: contactBuffers, countBuffers: countBuffers,
            overflowBuffers: overflowBuffers, pairMetricsBuffer: pairMetricsBuffer
        )
    }

    public func encodeStep(
        bounds: AABB,
        polygons: [SimulationPolygonSnapshot],
        deltaTime: Float,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialWorldFrameResources {
        guard status == .ready else { throw MetalSolverError.commandExecutionFailed }
        return try encodeSingleStep(
            bounds: bounds, polygons: polygons, deltaTime: deltaTime,
            sourceSensorBuffer: currentSensorBuffer,
            destinationSensorBuffer: destinationSensorBuffer,
            commandBuffer: commandBuffer
        )
    }

    public func encodeSteps(
        bounds: AABB,
        steps: [MetalRadialWorldStep],
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialWorldFrameResources {
        guard status == .ready, !steps.isEmpty else { throw MetalSolverError.commandExecutionFailed }
        var source = currentSensorBuffer
        var destination = destinationSensorBuffer
        var finalFrame: MetalRadialWorldFrameResources?
        for step in steps {
            finalFrame = try encodeSingleStep(
                bounds: bounds, polygons: step.polygons, deltaTime: step.deltaTime,
                sourceSensorBuffer: source, destinationSensorBuffer: destination,
                commandBuffer: commandBuffer
            )
            swap(&source, &destination)
        }
        return finalFrame!
    }

    private func encodeSingleStep(
        bounds: AABB,
        polygons: [SimulationPolygonSnapshot],
        deltaTime: Float,
        sourceSensorBuffer: MTLBuffer,
        destinationSensorBuffer: MTLBuffer,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialWorldFrameResources {
        let (vertices, polygonRecords) = encode(polygons: polygons)
        let vertexBuffer = try temporaryBuffer(vertices)
        let polygonBuffer = try temporaryBuffer(polygonRecords)
        var contactBuffers: [MTLBuffer] = []
        var countBuffers: [MTLBuffer] = []
        var overflowBuffers: [MTLBuffer] = []

        for (bubbleIndex, bubble) in templateWorld.bubbles.enumerated() {
            let range = resources.ranges[bubbleIndex]
            let naturalCapacity = max(1, range.sensorCount * (4 + polygons.reduce(0) { $0 + $1.worldVertices.count + 1 }))
            let capacity = environmentContactCapacity ?? naturalCapacity
            let contacts: MTLBuffer = try emptyBuffer(
                length: capacity * MemoryLayout<MetalRadialContact>.stride
            )
            let count: MTLBuffer = try emptyBuffer(length: MemoryLayout<UInt32>.stride)
            let overflow: MTLBuffer = try emptyBuffer(length: MemoryLayout<UInt32>.stride)
            memset(count.contents(), 0, MemoryLayout<UInt32>.stride)
            memset(overflow.contents(), 0, MemoryLayout<UInt32>.stride)
            contactBuffers.append(contacts)
            countBuffers.append(count)
            overflowBuffers.append(overflow)

            var environment = MetalRadialEnvironmentParameters(
                bounds: SIMD4(bounds.minimum.x, bounds.minimum.y, bounds.maximum.x, bounds.maximum.y),
                sensorCount: UInt32(range.sensorCount), polygonCount: UInt32(polygons.count),
                contactCapacity: UInt32(capacity)
            )
            guard let environmentEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MetalSolverError.commandEncodingFailed
            }
            environmentEncoder.setComputePipelineState(environmentPipeline)
            environmentEncoder.setBuffer(resources.bodyBuffer, offset: bubbleIndex * MemoryLayout<MetalRadialBody>.stride, index: 0)
            environmentEncoder.setBuffer(sourceSensorBuffer, offset: range.sensorStart * MemoryLayout<MetalRadialSensor>.stride, index: 1)
            environmentEncoder.setBuffer(resources.surfacePointBuffer, offset: range.sensorStart * MemoryLayout<SIMD2<Float>>.stride, index: 2)
            environmentEncoder.setBuffer(vertexBuffer, offset: 0, index: 3)
            environmentEncoder.setBuffer(polygonBuffer, offset: 0, index: 4)
            environmentEncoder.setBuffer(contacts, offset: 0, index: 5)
            environmentEncoder.setBuffer(count, offset: 0, index: 6)
            environmentEncoder.setBuffer(overflow, offset: 0, index: 7)
            environmentEncoder.setBytes(&environment, length: MemoryLayout<MetalRadialEnvironmentParameters>.stride, index: 8)
            environmentEncoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
            )
            environmentEncoder.endEncoding()

            var material = MetalRadialContactMaterial(bubble.material)
            var step = MetalRadialStepParameters(
                sensorCount: UInt32(range.sensorCount), contactCount: 0, deltaTime: deltaTime
            )
            guard let reduceEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MetalSolverError.commandEncodingFailed
            }
            reduceEncoder.setComputePipelineState(reducePipeline)
            reduceEncoder.setBuffer(contacts, offset: 0, index: 0)
            reduceEncoder.setBuffer(resources.bodyBuffer, offset: bubbleIndex * MemoryLayout<MetalRadialBody>.stride, index: 1)
            reduceEncoder.setBuffer(resources.loadHeaderBuffer, offset: bubbleIndex * MemoryLayout<SIMD4<Float>>.stride, index: 2)
            reduceEncoder.setBuffer(resources.compressionBuffer, offset: range.sensorStart * MemoryLayout<Float>.stride, index: 3)
            reduceEncoder.setBuffer(resources.pressureBuffer, offset: range.sensorStart * MemoryLayout<Float>.stride, index: 4)
            reduceEncoder.setBytes(&material, length: MemoryLayout<MetalRadialContactMaterial>.stride, index: 5)
            reduceEncoder.setBytes(&step, length: MemoryLayout<MetalRadialStepParameters>.stride, index: 6)
            reduceEncoder.setBuffer(count, offset: 0, index: 7)
            reduceEncoder.dispatchThreads(
                MTLSize(width: 1, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
            )
            reduceEncoder.endEncoding()
        }
        let orderedIndices = templateWorld.bubbles.indices.sorted {
            templateWorld.bubbles[$0].id < templateWorld.bubbles[$1].id
        }
        var pairRecords: [MetalRadialPairRecord] = []
        var contactStart = 0
        for firstPosition in orderedIndices.indices {
            for secondPosition in orderedIndices.index(after: firstPosition)..<orderedIndices.endIndex {
                let first = orderedIndices[firstPosition], second = orderedIndices[secondPosition]
                let capacity = 3 * (resources.ranges[first].sensorCount + resources.ranges[second].sensorCount)
                pairRecords.append(MetalRadialPairRecord(
                    bubblesAndRange: SIMD4(UInt32(first), UInt32(second), UInt32(contactStart), UInt32(capacity))
                ))
                contactStart += capacity
            }
        }
        let pairBuffer = try temporaryBuffer(pairRecords)
        let pairContactBuffer: MTLBuffer = try emptyBuffer(
            length: max(1, contactStart) * MemoryLayout<MetalRadialPairContact>.stride
        )
        let pairCountBuffer: MTLBuffer = try emptyBuffer(
            length: max(1, pairRecords.count) * MemoryLayout<UInt32>.stride
        )
        memset(pairCountBuffer.contents(), 0, max(1, pairRecords.count) * MemoryLayout<UInt32>.stride)
        let pairMetrics = try emptyBuffer(length: 3 * MemoryLayout<UInt32>.stride)
        memset(pairMetrics.contents(), 0, 3 * MemoryLayout<UInt32>.stride)
        var pairCount = UInt32(pairRecords.count)
        guard let pairEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalSolverError.commandEncodingFailed
        }
        pairEncoder.setComputePipelineState(generatePairPipeline)
        pairEncoder.setBuffer(resources.bodyBuffer, offset: 0, index: 0)
        pairEncoder.setBuffer(resources.descriptorBuffer, offset: 0, index: 1)
        pairEncoder.setBuffer(resources.surfacePointBuffer, offset: 0, index: 2)
        pairEncoder.setBuffer(pairBuffer, offset: 0, index: 3)
        pairEncoder.setBuffer(pairContactBuffer, offset: 0, index: 4)
        pairEncoder.setBuffer(pairCountBuffer, offset: 0, index: 5)
        pairEncoder.setBuffer(pairMetrics, offset: 0, index: 6)
        pairEncoder.setBytes(&pairCount, length: MemoryLayout<UInt32>.stride, index: 7)
        let pairWidth = max(1, min(generatePairPipeline.threadExecutionWidth, pairRecords.count))
        pairEncoder.dispatchThreads(
            MTLSize(width: pairRecords.count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: pairWidth, height: 1, depth: 1)
        )
        pairEncoder.endEncoding()
        guard let pairReduceEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalSolverError.commandEncodingFailed
        }
        pairReduceEncoder.setComputePipelineState(reducePairPipeline)
        pairReduceEncoder.setBuffer(resources.bodyBuffer, offset: 0, index: 0)
        pairReduceEncoder.setBuffer(resources.descriptorBuffer, offset: 0, index: 1)
        pairReduceEncoder.setBuffer(sourceSensorBuffer, offset: 0, index: 2)
        pairReduceEncoder.setBuffer(resources.surfacePointBuffer, offset: 0, index: 3)
        pairReduceEncoder.setBuffer(pairBuffer, offset: 0, index: 4)
        pairReduceEncoder.setBuffer(pairContactBuffer, offset: 0, index: 5)
        pairReduceEncoder.setBuffer(pairCountBuffer, offset: 0, index: 6)
        pairReduceEncoder.setBuffer(resources.loadHeaderBuffer, offset: 0, index: 7)
        pairReduceEncoder.setBuffer(resources.compressionBuffer, offset: 0, index: 8)
        pairReduceEncoder.setBuffer(resources.pressureBuffer, offset: 0, index: 9)
        pairReduceEncoder.setBytes(&pairCount, length: MemoryLayout<UInt32>.stride, index: 10)
        pairReduceEncoder.dispatchThreads(
            MTLSize(width: 1, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 1, height: 1, depth: 1)
        )
        pairReduceEncoder.endEncoding()
        return try encodeIntegration(
            deltaTime: deltaTime, commandBuffer: commandBuffer,
            contactBuffers: contactBuffers, countBuffers: countBuffers,
            overflowBuffers: overflowBuffers, pairMetricsBuffer: pairMetrics,
            sourceSensorBuffer: sourceSensorBuffer,
            destinationSensorBuffer: destinationSensorBuffer
        )
    }

    public static func substepCount(
        for world: RadialWorldState,
        polygons: [SimulationPolygonSnapshot],
        deltaTime: Float
    ) -> Int {
        let segmentLengths: [Float] = world.bubbles.flatMap { bubble -> [Float] in
            let points = bubble.surfacePoints
            return points.indices.map { index in
                let edge = points[(index + 1) % points.count] - points[index]
                return edge.dot(edge).squareRoot()
            }
        }.filter { $0 > 1e-5 }
        let shortestSegment: Float = segmentLengths.min() ?? 1
        let polygonSpeeds: [Float] = polygons.map { polygon -> Float in
            let radii: [Float] = polygon.worldVertices.map { point -> Float in
                let arm = point - polygon.position
                return arm.dot(arm).squareRoot()
            }
            let radius: Float = radii.max() ?? 0
            let linear = polygon.linearVelocity.dot(polygon.linearVelocity).squareRoot()
            return linear + abs(polygon.angularVelocity) * radius
        }
        let maximumPolygonSpeed: Float = polygonSpeeds.max() ?? 0
        return min(8, max(1, Int(ceil(maximumPolygonSpeed * deltaTime / shortestSegment))))
    }

    public func complete(
        frame: MetalRadialWorldFrameResources,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .completed else {
            status = .failed
            throw MetalSolverError.commandExecutionFailed
        }
        guard !frame.overflow else {
            status = .failed
            throw MetalSolverError.candidatePairOverflow
        }
        currentIsA = frame.sensorBuffer === sensorBufferA
        templateWorld = world
        resources = frameResources(sensorBuffer: currentSensorBuffer)
    }

    public func applyRemesh(_ decisions: [RadialRemeshDecision]) throws {
        let replacementWorld = try RadialWorldRemesher.apply(decisions, to: world)
        let replacement = try Self.allocate(device: device, allocator: allocator, world: replacementWorld)
        templateWorld = replacementWorld
        resources = replacement.resources
        sensorBufferA = replacement.sensorA
        sensorBufferB = replacement.sensorB
        currentIsA = true
    }

    private var currentSensorBuffer: MTLBuffer { currentIsA ? sensorBufferA : sensorBufferB }
    private var destinationSensorBuffer: MTLBuffer { currentIsA ? sensorBufferB : sensorBufferA }

    private func frameResources(
        sensorBuffer: MTLBuffer,
        contactBuffers: [MTLBuffer]? = nil,
        countBuffers: [MTLBuffer]? = nil,
        overflowBuffers: [MTLBuffer]? = nil,
        pairMetricsBuffer: MTLBuffer? = nil
    ) -> MetalRadialWorldFrameResources {
        MetalRadialWorldFrameResources(
            bodyBuffer: resources.bodyBuffer,
            descriptorBuffer: resources.descriptorBuffer,
            sensorBuffer: sensorBuffer,
            surfacePointBuffer: resources.surfacePointBuffer,
            rangeBuffer: resources.rangeBuffer,
            loadHeaderBuffer: resources.loadHeaderBuffer,
            compressionBuffer: resources.compressionBuffer,
            pressureBuffer: resources.pressureBuffer,
            ranges: resources.ranges,
            bubbleCount: resources.bubbleCount,
            sensorCount: resources.sensorCount,
            contactBuffers: contactBuffers ?? resources.contactBuffers,
            contactCountBuffers: countBuffers ?? resources.contactCountBuffers,
            overflowBuffers: overflowBuffers ?? resources.overflowBuffers,
            pairMetricsBuffer: pairMetricsBuffer ?? resources.pairMetricsBuffer
        )
    }

    private func unpackWorld() -> RadialWorldState {
        let bodies = resources.bodyBuffer.contents().bindMemory(
            to: MetalRadialBody.self, capacity: templateWorld.bubbles.count
        )
        let sensors = currentSensorBuffer.contents().bindMemory(
            to: MetalRadialSensor.self, capacity: resources.sensorCount
        )
        let bubbles = templateWorld.bubbles.enumerated().map { index, template -> RadialBubbleState in
            let body = bodies[index]
            let range = resources.ranges[index]
            let unpackedSensors = (0..<range.sensorCount).map { offset -> RadialSurfaceSensor in
                let value = sensors[range.sensorStart + offset]
                return RadialSurfaceSensor(
                    materialAngle: value.state.x, length: value.state.y,
                    radialVelocity: value.state.z, targetLength: value.state.w,
                    pressure: value.pressureAndPadding.x
                )
            }
            return RadialBubbleState(
                id: template.id,
                body: RadialBubbleBody(
                    center: Vector2(x: body.pose.x, y: body.pose.y),
                    linearVelocity: Vector2(x: body.pose.z, y: body.pose.w),
                    angle: body.motion.x, angularVelocity: body.motion.y,
                    mass: body.motion.z, momentOfInertia: body.motion.w
                ),
                sensors: unpackedSensors, targetRadius: body.target.x,
                birthProgress: body.target.y, maxSegmentLength: body.target.z,
                material: template.material, dynamics: template.dynamics
            )
        }
        return try! RadialWorldState(bubbles: bubbles)
    }

    private func encode(
        polygons: [SimulationPolygonSnapshot]
    ) -> ([SIMD2<Float>], [MetalRadialPolygon]) {
        var vertices: [SIMD2<Float>] = []
        var records: [MetalRadialPolygon] = []
        for polygon in polygons {
            let start = vertices.count
            vertices.append(contentsOf: polygon.worldVertices.map { SIMD2($0.x, $0.y) })
            records.append(MetalRadialPolygon(
                rangeAndMode: SIMD4(
                    UInt32(start), UInt32(polygon.worldVertices.count),
                    polygon.mode == .kinematic ? 1 : 0,
                    UInt32(truncatingIfNeeded: polygon.id.rawValue)
                ),
                positionAndVelocityX: SIMD4(
                    polygon.position.x, polygon.position.y, polygon.linearVelocity.x, 0
                ),
                velocityYAngularPadding: SIMD4(
                    polygon.linearVelocity.y, polygon.angularVelocity, 0, 0
                )
            ))
        }
        return (vertices, records)
    }

    private func temporaryBuffer<T>(_ values: [T]) throws -> MTLBuffer {
        let buffer: MTLBuffer = try emptyBuffer(
            length: max(1, values.count) * MemoryLayout<T>.stride
        )
        if !values.isEmpty {
            _ = values.withUnsafeBytes { memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
        }
        return buffer
    }

    private func emptyBuffer(length: Int) throws -> MTLBuffer {
        guard let buffer = allocator.makeBuffer(
            device: device, length: max(1, length), options: .storageModeShared
        ) else { throw MetalSolverError.bufferAllocationFailed }
        return buffer
    }

    private static func allocate(
        device: MTLDevice,
        allocator: any MetalBufferAllocator,
        world: RadialWorldState
    ) throws -> (resources: MetalRadialWorldFrameResources, sensorA: MTLBuffer, sensorB: MTLBuffer) {
        let bodies = world.bubbles.map(MetalRadialBody.init)
        let descriptors = zip(world.bubbles, world.ranges).map(MetalRadialWorldDescriptor.init)
        let sensors = world.bubbles.flatMap { $0.sensors.map(MetalRadialSensor.init) }
        let ranges = world.ranges.map {
            SIMD4<UInt32>(UInt32($0.bubbleIndex), UInt32($0.sensorStart), UInt32($0.sensorCount), 0)
        }
        func buffer<T>(_ values: [T]) throws -> MTLBuffer {
            guard let result = allocator.makeBuffer(
                device: device, length: max(1, values.count) * MemoryLayout<T>.stride,
                options: .storageModeShared
            ) else { throw MetalSolverError.bufferAllocationFailed }
            if !values.isEmpty {
                _ = values.withUnsafeBytes { memcpy(result.contents(), $0.baseAddress!, $0.count) }
            }
            return result
        }
        let bodyBuffer = try buffer(bodies)
        let descriptorBuffer = try buffer(descriptors)
        let sensorA = try buffer(sensors)
        let sensorB = try buffer(sensors)
        let surfacePoints: [SIMD2<Float>] = world.bubbles.flatMap {
            $0.surfacePoints.map { SIMD2($0.x, $0.y) }
        }
        let surfaceBuffer = try buffer(surfacePoints)
        let rangeBuffer = try buffer(ranges)
        let loadHeaderBuffer = try buffer(Array(repeating: SIMD4<Float>.zero, count: world.bubbles.count))
        let compressionBuffer = try buffer(Array(repeating: Float.zero, count: world.totalSensorCount))
        let pressureBuffer = try buffer(Array(repeating: Float.zero, count: world.totalSensorCount))
        let resources = MetalRadialWorldFrameResources(
            bodyBuffer: bodyBuffer, descriptorBuffer: descriptorBuffer,
            sensorBuffer: sensorA, surfacePointBuffer: surfaceBuffer,
            rangeBuffer: rangeBuffer, loadHeaderBuffer: loadHeaderBuffer,
            compressionBuffer: compressionBuffer, pressureBuffer: pressureBuffer,
            ranges: world.ranges, bubbleCount: world.bubbles.count,
            sensorCount: world.totalSensorCount,
            contactBuffers: [], contactCountBuffers: [], overflowBuffers: [],
            pairMetricsBuffer: nil
        )
        return (resources, sensorA, sensorB)
    }
}
