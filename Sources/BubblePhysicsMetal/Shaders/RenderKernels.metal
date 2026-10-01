#include <metal_stdlib>
using namespace metal;
struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct Uniforms { float2 worldSize; float2 padding; };
struct VertexOut { float4 position [[position]]; float2 local; };
vertex VertexOut bubbleVertex(uint id [[vertex_id]], device const MetalParticle *particles [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    float2 p = particles[id].position; VertexOut out;
    out.position = float4(p.x / u.worldSize.x * 2.0 - 1.0, 1.0 - p.y / u.worldSize.y * 2.0, 0, 1);
    out.local = p / u.worldSize; return out;
}
fragment float4 bubbleFragment(VertexOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    float glow = 0.82 + 0.18 * (1.0 - in.local.y); return float4(color.rgb * glow, color.a);
}
