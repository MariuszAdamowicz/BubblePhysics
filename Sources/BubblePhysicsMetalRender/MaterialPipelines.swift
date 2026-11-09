import BubblePhysicsModel
import BubblePhysicsNativeMetal
import Metal

/// Potoki rysowania materiałów: jeden na (rodzaj geometrii, tryb mieszania, format celu). Tworzone leniwie i używane
/// ponownie między klatkami.
@MainActor
final class MaterialPipelines {
    enum Geometry: Hashable { case bubble, body, decal }

    private struct Key: Hashable {
        let geometry: Geometry
        let blend: RenderBlendMode
        let format: MTLPixelFormat
    }

    private let device: MTLDevice
    private let functions: NativeRenderFunctions
    private var pipelines: [Key: MTLRenderPipelineState] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        functions = try NativeMetalRenderHandoff.makeFunctions(device: device)
    }

    func pipeline(_ geometry: Geometry, blend: RenderBlendMode, format: MTLPixelFormat) throws -> MTLRenderPipelineState {
        let key = Key(geometry: geometry, blend: blend, format: format)
        if let cached = pipelines[key] { return cached }
        let descriptor = MTLRenderPipelineDescriptor()
        switch geometry {
        case .bubble: descriptor.vertexFunction = functions.bubbleVertex; descriptor.fragmentFunction = functions.bubbleFragment
        case .body: descriptor.vertexFunction = functions.bodyVertex; descriptor.fragmentFunction = functions.bodyFragment
        case .decal: descriptor.vertexFunction = functions.decalVertex; descriptor.fragmentFunction = functions.decalFragment
        }
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        // Fragment zwraca kolor z alfą przemnożoną (nieprzezroczysty: alfa 1), więc oba tryby z alfą składają `one + …`.
        switch blend {
        case .opaque:
            attachment.isBlendingEnabled = false
        case .alpha:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one; attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha; attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one; attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .one; attachment.destinationAlphaBlendFactor = .one
        }
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        pipelines[key] = pipeline
        return pipeline
    }

    /// Rekord materiału dla shaderów.
    nonisolated static func record(for material: RenderMaterial) -> NativeRenderMaterial {
        func vector(_ color: RGBA) -> SIMD4<Float> { SIMD4(color.red, color.green, color.blue, color.alpha) }
        let blend: Float
        switch material.blend {
        case .opaque: blend = 0
        case .alpha: blend = 1
        case .additive: blend = 2
        }
        return NativeRenderMaterial(color: vector(material.color), outlineColor: vector(material.outline.color),
            parameters: SIMD4(material.outline.width, blend, material.bubbleMapping == .masked ? 1 : 0, 0),
            uv: SIMD4(material.uvOffset.x, material.uvOffset.y, material.uvScale.x, material.uvScale.y))
    }
}
