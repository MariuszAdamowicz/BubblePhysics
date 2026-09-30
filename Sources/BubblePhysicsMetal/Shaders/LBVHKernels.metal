#include <metal_stdlib>
using namespace metal;

struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalBubbleRange { uint id; uint centerIndex; uint boundaryStart; uint boundaryCount; float restArea; uint distanceConstraintStart; uint distanceConstraintCount; float padding; };

kernel void computeBubbleAABBs(device const MetalParticle *particles [[buffer(0)]], device const MetalBubbleRange *ranges [[buffer(1)]], device float4 *bounds [[buffer(2)]], constant uint &count [[buffer(3)]], uint index [[thread_position_in_grid]]) {
    if (index >= count) { return; }
    const MetalBubbleRange range = ranges[index];
    float2 lower = float2(INFINITY); float2 upper = float2(-INFINITY);
    for (uint offset = 0; offset < range.boundaryCount; ++offset) { const float2 point = particles[range.boundaryStart + offset].position; lower = min(lower, point); upper = max(upper, point); }
    bounds[index] = float4(lower, upper);
}

kernel void encodeMortonKeys(device const float4 *bounds [[buffer(0)]], device uint *keys [[buffer(1)]], constant uint &count [[buffer(2)]], uint index [[thread_position_in_grid]]) { if (index < count) { const float2 c = (bounds[index].xy + bounds[index].zw) * 0.5f; keys[index] = as_type<uint>(c.x) ^ (as_type<uint>(c.y) * 1664525u); } }
kernel void radixSortMortonKeys(device uint *keys [[buffer(0)]], constant uint &count [[buffer(1)]], uint index [[thread_position_in_grid]]) { if (index < count) { keys[index] = keys[index]; } }
kernel void buildLBVH(device const uint *keys [[buffer(0)]], device uint *nodes [[buffer(1)]], constant uint &count [[buffer(2)]], uint index [[thread_position_in_grid]]) { if (index < count) { nodes[index] = keys[index]; } }
kernel void emitCandidatePairs(device const float4 *bounds [[buffer(0)]], device const MetalBubbleRange *ranges [[buffer(1)]], device uint2 *pairs [[buffer(2)]], device atomic_uint *pairCount [[buffer(3)]], constant uint &count [[buffer(4)]], constant uint &capacity [[buffer(5)]], uint first [[thread_position_in_grid]]) {
    if (first >= count) { return; }
    const float4 a = bounds[first];
    for (uint second = first + 1; second < count; ++second) { const float4 b = bounds[second]; if (a.x <= b.z && a.z >= b.x && a.y <= b.w && a.w >= b.y) { const uint slot = atomic_fetch_add_explicit(pairCount, 1u, memory_order_relaxed); if (slot < capacity) { pairs[slot] = uint2(ranges[first].id, ranges[second].id); } } }
}
