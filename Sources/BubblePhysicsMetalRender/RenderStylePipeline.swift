import Metal
import BubblePhysics

/// Pipeline gry korzysta z `makeContourVertexFunction()` renderera.
/// Jego fragment shader otrzymuje `stage_in` z polami MSL:
/// `float4 position [[position]]; float2 worldPosition;`.
/// Kanały prezentacyjne są przekazywane przed rysowaniem każdego obiektu.
@MainActor
public struct RenderStylePipeline {
    public let state: MTLRenderPipelineState
    public let encodeChannels: (MTLRenderCommandEncoder, [ParameterID: Float]) -> Void

    public init(state: MTLRenderPipelineState,
                encodeChannels: @escaping (MTLRenderCommandEncoder, [ParameterID: Float]) -> Void) {
        self.state = state
        self.encodeChannels = encodeChannels
    }
}
