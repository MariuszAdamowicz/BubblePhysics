import Foundation
import Metal

public final class MetalBubbleSolver {
    public let device: MTLDevice
    public let loadedFunctionNames: Set<String>

    public var isAvailable: Bool { true }

    public init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device,
              let shaderURL = Bundle.module.url(forResource: "BubblePhysicsKernels", withExtension: "metal"),
              let source = try? String(contentsOf: shaderURL),
              let library = try? device.makeLibrary(source: source, options: nil),
              library.makeFunction(name: "predictParticles") != nil
        else { return nil }

        self.device = device
        loadedFunctionNames = ["predictParticles"]
    }
}
