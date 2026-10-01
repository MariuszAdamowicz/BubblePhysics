import Metal
import BubblePhysics

public final class MetalRadialSimulation: @unchecked Sendable {
    private let device: MTLDevice
    private let predictPipeline: MTLComputePipelineState
    private let buildSurfacePipeline: MTLComputePipelineState
    private let reduceContactsPipeline: MTLComputePipelineState
    private let integrateSurfacePipeline: MTLComputePipelineState
    private let generateEnvironmentPipeline: MTLComputePipelineState
    private let bodyBuffer: MTLBuffer
    private let sensorBufferA: MTLBuffer
    private let sensorBufferB: MTLBuffer
    private let surfacePointBuffer: MTLBuffer
    private let loadHeaderBuffer: MTLBuffer
    private let compressionBuffer: MTLBuffer
    private let pressureBuffer: MTLBuffer
    private let contactCountBuffer: MTLBuffer
    private let contactOverflowBuffer: MTLBuffer
    private var contactBuffer: MTLBuffer
    private var contactCapacity: Int
    private var currentIsA = true
    private var templateState: RadialBubbleState

    public init(device: MTLDevice, state: RadialBubbleState) throws {
        let functionNames = [
            "radialPredictBody", "radialBuildSurface",
            "radialReduceContacts", "radialIntegrateSurface"
        ]
        guard let library = MetalShaderLibrary.load(
            device: device,
            sourceName: "RadialBubbleKernels",
            requiredFunctions: functionNames
        ) else { throw MetalSolverError.metalUnavailable }
        guard
            let predictFunction = library.makeFunction(name: functionNames[0]),
            let buildFunction = library.makeFunction(name: functionNames[1]),
            let reduceFunction = library.makeFunction(name: functionNames[2]),
            let integrateFunction = library.makeFunction(name: functionNames[3])
        else { throw MetalSolverError.metalUnavailable }
        guard
            let environmentLibrary = MetalShaderLibrary.load(
                device: device,
                sourceName: "RadialContactKernels",
                requiredFunctions: ["radialGenerateEnvironmentContacts"]
            ),
            let environmentFunction = environmentLibrary.makeFunction(name: "radialGenerateEnvironmentContacts")
        else { throw MetalSolverError.metalUnavailable }

        do {
            predictPipeline = try device.makeComputePipelineState(function: predictFunction)
            buildSurfacePipeline = try device.makeComputePipelineState(function: buildFunction)
            reduceContactsPipeline = try device.makeComputePipelineState(function: reduceFunction)
            integrateSurfacePipeline = try device.makeComputePipelineState(function: integrateFunction)
            generateEnvironmentPipeline = try device.makeComputePipelineState(function: environmentFunction)
        } catch {
            throw MetalSolverError.metalUnavailable
        }

        let sensorCount = state.sensors.count
        guard
            let bodyBuffer = device.makeBuffer(length: MemoryLayout<MetalRadialBody>.stride, options: .storageModeShared),
            let sensorBufferA = device.makeBuffer(length: sensorCount * MemoryLayout<MetalRadialSensor>.stride, options: .storageModeShared),
            let sensorBufferB = device.makeBuffer(length: sensorCount * MemoryLayout<MetalRadialSensor>.stride, options: .storageModeShared),
            let surfacePointBuffer = device.makeBuffer(length: sensorCount * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
            let loadHeaderBuffer = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared),
            let compressionBuffer = device.makeBuffer(length: sensorCount * MemoryLayout<Float>.stride, options: .storageModeShared),
            let pressureBuffer = device.makeBuffer(length: sensorCount * MemoryLayout<Float>.stride, options: .storageModeShared),
            let contactCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let contactOverflowBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared),
            let contactBuffer = device.makeBuffer(length: MemoryLayout<MetalRadialContact>.stride, options: .storageModeShared)
        else { throw MetalSolverError.bufferAllocationFailed }

        self.device = device
        self.bodyBuffer = bodyBuffer
        self.sensorBufferA = sensorBufferA
        self.sensorBufferB = sensorBufferB
        self.surfacePointBuffer = surfacePointBuffer
        self.loadHeaderBuffer = loadHeaderBuffer
        self.compressionBuffer = compressionBuffer
        self.pressureBuffer = pressureBuffer
        self.contactCountBuffer = contactCountBuffer
        self.contactOverflowBuffer = contactOverflowBuffer
        self.contactBuffer = contactBuffer
        contactCapacity = 1
        templateState = state
        copy([MetalRadialBody(state)], to: bodyBuffer)
        let sensors = state.sensors.map(MetalRadialSensor.init)
        copy(sensors, to: sensorBufferA)
        copy(sensors, to: sensorBufferB)
        contactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        contactOverflowBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        upload(load: .zero(sensorCount: sensorCount))
    }

    public var state: RadialBubbleState {
        let body = bodyBuffer.contents().bindMemory(to: MetalRadialBody.self, capacity: 1).pointee
        let sensorPointer = currentSensorBuffer.contents().bindMemory(
            to: MetalRadialSensor.self,
            capacity: templateState.sensors.count
        )
        let metalSensors = Array(UnsafeBufferPointer(start: sensorPointer, count: templateState.sensors.count))
        let sensors = metalSensors.map {
            RadialSurfaceSensor(
                materialAngle: $0.state.x,
                length: $0.state.y,
                radialVelocity: $0.state.z,
                targetLength: $0.state.w,
                pressure: $0.pressureAndPadding.x
            )
        }
        return RadialBubbleState(
            id: templateState.id,
            body: RadialBubbleBody(
                center: Vector2(x: body.pose.x, y: body.pose.y),
                linearVelocity: Vector2(x: body.pose.z, y: body.pose.w),
                angle: body.motion.x,
                angularVelocity: body.motion.y,
                mass: body.motion.z,
                momentOfInertia: body.motion.w
            ),
            sensors: sensors,
            targetRadius: body.target.x,
            birthProgress: body.target.y,
            maxSegmentLength: body.target.z,
            material: templateState.material,
            dynamics: templateState.dynamics
        )
    }

    public func encodeStep(
        load: RadialBodyLoad,
        deltaTime: Float,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialFrameResources {
        precondition(load.sensorCompression.count == templateState.sensors.count)
        precondition(load.sensorPressureDeltas.count == templateState.sensors.count)
        upload(load: load)
        contactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        return try encode(deltaTime: deltaTime, contactCount: 0, reduceContacts: false, commandBuffer: commandBuffer)
    }

    public func encodeStep(
        contacts: [RadialSurfaceContact],
        deltaTime: Float,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialFrameResources {
        let ordered = contacts.sorted {
            if $0.sourceID != $1.sourceID { return $0.sourceID < $1.sourceID }
            if $0.sensorStartIndex != $1.sensorStartIndex { return $0.sensorStartIndex < $1.sensorStartIndex }
            return $0.sensorEndIndex < $1.sensorEndIndex
        }
        try ensureContactCapacity(ordered.count)
        copy(ordered.map(MetalRadialContact.init), to: contactBuffer)
        contactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = UInt32(ordered.count)
        return try encode(deltaTime: deltaTime, contactCount: ordered.count, reduceContacts: true, commandBuffer: commandBuffer)
    }

    public func encodeStep(
        bounds: AABB,
        polygons: [SimulationPolygonSnapshot],
        deltaTime: Float,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialFrameResources {
        let maximumContacts = templateState.sensors.count * (4 + polygons.count)
        try ensureContactCapacity(maximumContacts)
        let (vertices, records) = encode(polygons: polygons)
        guard
            let vertexBuffer = device.makeBuffer(
                length: max(1, vertices.count) * MemoryLayout<SIMD2<Float>>.stride,
                options: .storageModeShared
            ),
            let polygonBuffer = device.makeBuffer(
                length: max(1, records.count) * MemoryLayout<MetalRadialPolygon>.stride,
                options: .storageModeShared
            )
        else { throw MetalSolverError.bufferAllocationFailed }
        copy(vertices, to: vertexBuffer)
        copy(records, to: polygonBuffer)
        contactCountBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0
        contactOverflowBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee = 0

        var stepParameters = MetalRadialStepParameters(
            sensorCount: UInt32(templateState.sensors.count),
            contactCount: 0,
            deltaTime: deltaTime
        )
        try encodeSurfaceBuild(
            sensors: currentSensorBuffer,
            parameters: &stepParameters,
            commandBuffer: commandBuffer
        )
        var environment = MetalRadialEnvironmentParameters(
            bounds: SIMD4(bounds.minimum.x, bounds.minimum.y, bounds.maximum.x, bounds.maximum.y),
            sensorCount: UInt32(templateState.sensors.count),
            polygonCount: UInt32(polygons.count),
            contactCapacity: UInt32(maximumContacts)
        )
        guard let environmentEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        environmentEncoder.setComputePipelineState(generateEnvironmentPipeline)
        environmentEncoder.setBuffer(bodyBuffer, offset: 0, index: 0)
        environmentEncoder.setBuffer(currentSensorBuffer, offset: 0, index: 1)
        environmentEncoder.setBuffer(surfacePointBuffer, offset: 0, index: 2)
        environmentEncoder.setBuffer(vertexBuffer, offset: 0, index: 3)
        environmentEncoder.setBuffer(polygonBuffer, offset: 0, index: 4)
        environmentEncoder.setBuffer(contactBuffer, offset: 0, index: 5)
        environmentEncoder.setBuffer(contactCountBuffer, offset: 0, index: 6)
        environmentEncoder.setBuffer(contactOverflowBuffer, offset: 0, index: 7)
        environmentEncoder.setBytes(&environment, length: MemoryLayout<MetalRadialEnvironmentParameters>.stride, index: 8)
        dispatch(environmentEncoder, pipeline: generateEnvironmentPipeline, count: 1)
        environmentEncoder.endEncoding()

        return try encode(deltaTime: deltaTime, contactCount: 0, reduceContacts: true, commandBuffer: commandBuffer)
    }

    public func complete(
        frame: MetalRadialFrameResources,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard commandBuffer.status == .completed else { throw MetalSolverError.commandExecutionFailed }
        guard contactOverflowBuffer.contents().bindMemory(to: UInt32.self, capacity: 1).pointee == 0 else {
            throw MetalSolverError.candidatePairOverflow
        }
        currentIsA.toggle()
        templateState = state
    }

    private var currentSensorBuffer: MTLBuffer { currentIsA ? sensorBufferA : sensorBufferB }
    private var destinationSensorBuffer: MTLBuffer { currentIsA ? sensorBufferB : sensorBufferA }

    private func encode(
        deltaTime: Float,
        contactCount: Int,
        reduceContacts: Bool,
        commandBuffer: MTLCommandBuffer
    ) throws -> MetalRadialFrameResources {
        var material = MetalRadialMaterial(templateState.dynamics)
        var contactMaterial = MetalRadialContactMaterial(templateState.material)
        var parameters = MetalRadialStepParameters(
            sensorCount: UInt32(templateState.sensors.count),
            contactCount: UInt32(contactCount),
            deltaTime: deltaTime
        )

        if reduceContacts {
            guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
            encoder.setComputePipelineState(reduceContactsPipeline)
            encoder.setBuffer(contactBuffer, offset: 0, index: 0)
            encoder.setBuffer(bodyBuffer, offset: 0, index: 1)
            encoder.setBuffer(loadHeaderBuffer, offset: 0, index: 2)
            encoder.setBuffer(compressionBuffer, offset: 0, index: 3)
            encoder.setBuffer(pressureBuffer, offset: 0, index: 4)
            encoder.setBytes(&contactMaterial, length: MemoryLayout<MetalRadialContactMaterial>.stride, index: 5)
            encoder.setBytes(&parameters, length: MemoryLayout<MetalRadialStepParameters>.stride, index: 6)
            encoder.setBuffer(contactCountBuffer, offset: 0, index: 7)
            dispatch(encoder, pipeline: reduceContactsPipeline, count: 1)
            encoder.endEncoding()
        }

        guard let bodyEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        bodyEncoder.setComputePipelineState(predictPipeline)
        bodyEncoder.setBuffer(bodyBuffer, offset: 0, index: 0)
        bodyEncoder.setBuffer(loadHeaderBuffer, offset: 0, index: 1)
        bodyEncoder.setBytes(&material, length: MemoryLayout<MetalRadialMaterial>.stride, index: 2)
        bodyEncoder.setBytes(&parameters, length: MemoryLayout<MetalRadialStepParameters>.stride, index: 3)
        dispatch(bodyEncoder, pipeline: predictPipeline, count: 1)
        bodyEncoder.endEncoding()

        guard let surfaceEncoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        surfaceEncoder.setComputePipelineState(integrateSurfacePipeline)
        surfaceEncoder.setBuffer(currentSensorBuffer, offset: 0, index: 0)
        surfaceEncoder.setBuffer(destinationSensorBuffer, offset: 0, index: 1)
        surfaceEncoder.setBuffer(bodyBuffer, offset: 0, index: 2)
        surfaceEncoder.setBuffer(compressionBuffer, offset: 0, index: 3)
        surfaceEncoder.setBuffer(pressureBuffer, offset: 0, index: 4)
        surfaceEncoder.setBytes(&material, length: MemoryLayout<MetalRadialMaterial>.stride, index: 5)
        surfaceEncoder.setBytes(&parameters, length: MemoryLayout<MetalRadialStepParameters>.stride, index: 6)
        dispatch(surfaceEncoder, pipeline: integrateSurfacePipeline, count: templateState.sensors.count)
        surfaceEncoder.endEncoding()

        try encodeSurfaceBuild(sensors: destinationSensorBuffer, parameters: &parameters, commandBuffer: commandBuffer)

        return MetalRadialFrameResources(
            bodyBuffer: bodyBuffer,
            sensorBuffer: destinationSensorBuffer,
            surfacePointBuffer: surfacePointBuffer,
            loadHeaderBuffer: loadHeaderBuffer,
            compressionBuffer: compressionBuffer,
            pressureBuffer: pressureBuffer,
            contactCountBuffer: contactCountBuffer,
            contactOverflowBuffer: contactOverflowBuffer,
            sensorCount: templateState.sensors.count
        )
    }

    private func encodeSurfaceBuild(
        sensors: MTLBuffer,
        parameters: inout MetalRadialStepParameters,
        commandBuffer: MTLCommandBuffer
    ) throws {
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { throw MetalSolverError.commandEncodingFailed }
        encoder.setComputePipelineState(buildSurfacePipeline)
        encoder.setBuffer(bodyBuffer, offset: 0, index: 0)
        encoder.setBuffer(sensors, offset: 0, index: 1)
        encoder.setBuffer(surfacePointBuffer, offset: 0, index: 2)
        encoder.setBytes(&parameters, length: MemoryLayout<MetalRadialStepParameters>.stride, index: 3)
        dispatch(encoder, pipeline: buildSurfacePipeline, count: templateState.sensors.count)
        encoder.endEncoding()
    }

    private func encode(polygons: [SimulationPolygonSnapshot]) -> ([SIMD2<Float>], [MetalRadialPolygon]) {
        var vertices: [SIMD2<Float>] = []
        var records: [MetalRadialPolygon] = []
        for polygon in polygons {
            let start = vertices.count
            vertices.append(contentsOf: polygon.worldVertices.map { SIMD2($0.x, $0.y) })
            records.append(MetalRadialPolygon(
                rangeAndMode: SIMD4(
                    UInt32(start), UInt32(polygon.worldVertices.count),
                    polygon.mode == .kinematic ? 1 : 0, UInt32(truncatingIfNeeded: polygon.id.rawValue)
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

    private func upload(load: RadialBodyLoad) {
        copy([SIMD4(load.force.x, load.force.y, load.torque, 0)], to: loadHeaderBuffer)
        copy(load.sensorCompression, to: compressionBuffer)
        copy(load.sensorPressureDeltas, to: pressureBuffer)
    }

    private func ensureContactCapacity(_ required: Int) throws {
        guard required > contactCapacity else { return }
        guard let replacement = device.makeBuffer(
            length: required * MemoryLayout<MetalRadialContact>.stride,
            options: .storageModeShared
        ) else { throw MetalSolverError.bufferAllocationFailed }
        contactBuffer = replacement
        contactCapacity = required
    }

    private func copy<T>(_ values: [T], to buffer: MTLBuffer) {
        guard !values.isEmpty else { return }
        _ = values.withUnsafeBytes { bytes in
            memcpy(buffer.contents(), bytes.baseAddress!, bytes.count)
        }
    }

    private func dispatch(_ encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, count: Int) {
        let width = max(1, min(pipeline.threadExecutionWidth, count))
        encoder.dispatchThreads(
            MTLSize(width: count, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1)
        )
    }
}
