import Foundation
import Metal
import BubblePhysics

public final class MetalBubbleSolver {
    public let device: MTLDevice
    public let loadedFunctionNames: Set<String>
    private let capacityManager: MetalCapacityManager

    public var isAvailable: Bool { true }
    public var capacities: MetalBufferCapacities { capacityManager.capacities }

    public init?(
        device: MTLDevice? = MTLCreateSystemDefaultDevice(),
        capacities: MetalBufferCapacities = .init()
    ) {
        guard let device,
              let shaderURL = Bundle.module.url(forResource: "BubblePhysicsKernels", withExtension: "metal"),
              let source = try? String(contentsOf: shaderURL),
              let library = try? device.makeLibrary(source: source, options: nil),
              library.makeFunction(name: "predictParticles") != nil
        else { return nil }

        self.device = device
        loadedFunctionNames = ["predictParticles"]
        capacityManager = MetalCapacityManager(capacities: capacities)
    }

    public func step(snapshot: MetalWorldSnapshot, commands: [WorldCommand]) async throws -> MetalStepTelemetry {
        let bubbleCount = snapshot.bubbleRanges.count
        let reservedPairCount = bubbleCount * max(0, bubbleCount - 1) / 2
        let requirements = MetalBufferRequirements(
            pairs: reservedPairCount,
            contacts: reservedPairCount,
            corrections: reservedPairCount * 2
        )
        let didRetry = capacityManager.ensureCapacity(for: requirements)
        _ = commands
        return MetalStepTelemetry(
            candidatePairCount: reservedPairCount,
            contactCount: 0,
            correctionCount: 0,
            didOverflow: false,
            didRetry: didRetry
        )
    }
}
