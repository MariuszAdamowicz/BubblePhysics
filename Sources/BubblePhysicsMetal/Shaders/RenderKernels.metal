#include <metal_stdlib>
using namespace metal;
struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct Uniforms { float2 worldToClipScale; float2 worldToClipOffset; };
float2 worldToClip(float2 point, constant Uniforms &u) {
    return point * u.worldToClipScale + u.worldToClipOffset;
}
struct VertexOut { float4 position [[position]]; float2 local; };
vertex VertexOut bubbleVertex(uint id [[vertex_id]], device const MetalParticle *particles [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    float2 p = particles[id].position; VertexOut out;
    const float2 clip = worldToClip(p, u);
    out.position = float4(clip, 0, 1);
    out.local = clip * float2(0.5, -0.5) + 0.5; return out;
}
fragment float4 bubbleFragment(VertexOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    float glow = 0.82 + 0.18 * (1.0 - in.local.y); return float4(color.rgb * glow, color.a);
}

struct LabelInstance { uint centerIndex; uint boundaryStart; uint boundaryCount; uint padding; float2 uvOrigin; float2 uvSize; float2 halfSize; };
struct LabelOut { float4 position [[position]]; float2 uv; };
vertex LabelOut labelVertex(uint vertexID [[vertex_id]], uint instanceID [[instance_id]], device const MetalParticle *particles [[buffer(0)]], constant Uniforms &u [[buffer(1)]], device const LabelInstance *instances [[buffer(2)]]) {
    constexpr float2 corners[6] = { {-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1} };
    const LabelInstance item = instances[instanceID];
    const float2 center = particles[item.centerIndex].position;
    const float2 previousCenter = particles[item.centerIndex].previousPosition;
    float2 currentAxis = float2(0);
    float2 previousAxis = float2(0);
    const uint sampleCount = min(8u, item.boundaryCount);
    for (uint sample = 0; sample < sampleCount; ++sample) {
        const uint offset = sample * item.boundaryCount / sampleCount;
        const MetalParticle point = particles[item.boundaryStart + offset];
        const float2 currentDirection = point.position - center;
        const float2 previousDirection = point.previousPosition - previousCenter;
        if (length_squared(currentDirection) > 0.000001f) { currentAxis += normalize(currentDirection); }
        if (length_squared(previousDirection) > 0.000001f) { previousAxis += normalize(previousDirection); }
    }
    float2 axis = normalize(currentAxis * 0.8f + previousAxis * 0.2f);
    if (!all(isfinite(axis))) { axis = float2(1, 0); }
    const float2 perpendicular = float2(-axis.y, axis.x);
    const float2 corner = corners[vertexID];
    const float2 world = center + axis * corner.x * item.halfSize.x + perpendicular * corner.y * item.halfSize.y;
    LabelOut out; out.position = float4(worldToClip(world, u), 0, 1);
    out.uv = item.uvOrigin + (corner * 0.5 + 0.5) * item.uvSize; return out;
}
fragment float4 labelFragment(LabelOut in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    const float alpha = atlas.sample(s, in.uv).r; return float4(0.06, 0.08, 0.12, alpha);
}
vertex VertexOut polygonVertex(uint id [[vertex_id]], device const float2 *vertices [[buffer(0)]], constant Uniforms &u [[buffer(1)]]) {
    const float2 p = vertices[id]; const float2 clip = worldToClip(p, u); VertexOut out; out.position = float4(clip, 0, 1); out.local = clip * float2(0.5, -0.5) + 0.5; return out;
}
