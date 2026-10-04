import Metal

/// Pipeline bootstrap for the iOS reference backend. macOS supports host tests only.
/// This facade does not yet execute a simulation step.
public final class ReferenceMetalSolver {
    public let device: MTLDevice
    public let loadedFunctionNames: Set<String>
    private let residualPipeline: MTLComputePipelineState
    let capacityManager: ReferenceMetalCapacityManager

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let library = try? device.makeLibrary(source: Self.bootstrapSource, options: nil),
              let function = library.makeFunction(name: "referenceBuildResidual"),
              let pipeline = try? device.makeComputePipelineState(function: function)
        else { return nil }

        self.device = device
        capacityManager = ReferenceMetalCapacityManager(device: device)
        residualPipeline = pipeline
        loadedFunctionNames = [function.name]
    }

    // Availability probe only; Task 3 replaces this with the numerical operator.
    // No public dispatch API exposes this placeholder as a residual computation.
    private static let bootstrapSource = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void referenceBuildResidual(uint index [[thread_position_in_grid]]) {}
    """
}
