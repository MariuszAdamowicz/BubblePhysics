import Metal
import BubblePhysics

public final class MetalRadialWorldSimulation: @unchecked Sendable {
    private let device: MTLDevice
    private let allocator: any MetalBufferAllocator
    private let pipeline: MTLComputePipelineState
    private var sensorBufferA: MTLBuffer
    private var sensorBufferB: MTLBuffer
    private var currentIsA = true
    private var templateWorld: RadialWorldState
    public private(set) var resources: MetalRadialWorldFrameResources
    public private(set) var status: MetalRadialWorldStatus = .ready

    public init(
        device: MTLDevice,
        world: RadialWorldState,
        allocator: any MetalBufferAllocator = DefaultMetalBufferAllocator()
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
        templateWorld = world
        let packed = try Self.allocate(device: device, allocator: allocator, world: world)
        resources = packed.resources
        sensorBufferA = packed.sensorA
        sensorBufferB = packed.sensorB
    }

    public var world: RadialWorldState { unpackWorld() }

    public func encodeFreeStep(
        deltaTime: Float,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialWorldFrameResources {
        guard status == .ready else { throw MetalSolverError.commandExecutionFailed }
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
        encoder.setBuffer(currentSensorBuffer, offset: 0, index: 2)
        encoder.setBuffer(destinationSensorBuffer, offset: 0, index: 3)
        encoder.setBuffer(resources.surfacePointBuffer, offset: 0, index: 4)
        encoder.setBytes(&parameters, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 5)
        let width = max(1, min(pipeline.threadExecutionWidth, resources.bubbleCount))
        encoder.dispatchThreads(
            MTLSize(width: resources.bubbleCount, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
        encoder.endEncoding()
        return frameResources(sensorBuffer: destinationSensorBuffer)
    }

    public func complete(
        frame: MetalRadialWorldFrameResources,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .completed else {
            status = .failed
            throw MetalSolverError.commandExecutionFailed
        }
        currentIsA.toggle()
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

    private func frameResources(sensorBuffer: MTLBuffer) -> MetalRadialWorldFrameResources {
        MetalRadialWorldFrameResources(
            bodyBuffer: resources.bodyBuffer,
            descriptorBuffer: resources.descriptorBuffer,
            sensorBuffer: sensorBuffer,
            surfacePointBuffer: resources.surfacePointBuffer,
            rangeBuffer: resources.rangeBuffer,
            ranges: resources.ranges,
            bubbleCount: resources.bubbleCount,
            sensorCount: resources.sensorCount
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
        let resources = MetalRadialWorldFrameResources(
            bodyBuffer: bodyBuffer, descriptorBuffer: descriptorBuffer,
            sensorBuffer: sensorA, surfacePointBuffer: surfaceBuffer,
            rangeBuffer: rangeBuffer, ranges: world.ranges,
            bubbleCount: world.bubbles.count, sensorCount: world.totalSensorCount
        )
        return (resources, sensorA, sensorB)
    }
}
