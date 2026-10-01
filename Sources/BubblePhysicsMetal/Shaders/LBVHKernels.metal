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

kernel void encodeMortonKeys(device const float4 *bounds [[buffer(0)]], device uint2 *keys [[buffer(1)]], constant uint &count [[buffer(2)]], uint index [[thread_position_in_grid]]) { if (index < count) { const uint bits = as_type<uint>(bounds[index].x); keys[index] = uint2((bits & 0x80000000u) ? ~bits : (bits ^ 0x80000000u), index); } }
kernel void radixSortMortonKeys(device uint2 *keys [[buffer(0)]], constant uint &count [[buffer(1)]], constant uint &stage [[buffer(2)]], constant uint &stride [[buffer(3)]], uint index [[thread_position_in_grid]]) { const uint partner = index ^ stride; if (index >= count || partner >= count || partner <= index) { return; } const bool ascending = (index & stage) == 0; const bool swap = ascending ? keys[index].x > keys[partner].x : keys[index].x < keys[partner].x; if (swap) { const uint2 value = keys[index]; keys[index] = keys[partner]; keys[partner] = value; } }
kernel void sortMortonKeysInThreadgroup(
    device uint2 *keys [[buffer(0)]],
    constant uint &count [[buffer(1)]],
    threadgroup uint2 *sharedKeys [[threadgroup(0)]],
    uint threadIndex [[thread_index_in_threadgroup]],
    uint threadCount [[threads_per_threadgroup]]
) {
    for (uint index = threadIndex; index < count; index += threadCount) {
        sharedKeys[index] = keys[index];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stage = 2; stage <= count; stage *= 2) {
        for (uint stride = stage / 2; stride > 0; stride /= 2) {
            for (uint index = threadIndex; index < count; index += threadCount) {
                const uint partner = index ^ stride;
                if (partner <= index) { continue; }
                const bool ascending = (index & stage) == 0;
                const uint2 first = sharedKeys[index];
                const uint2 second = sharedKeys[partner];
                const bool swap = ascending ? first.x > second.x : first.x < second.x;
                if (swap) {
                    sharedKeys[index] = second;
                    sharedKeys[partner] = first;
                }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }
    for (uint index = threadIndex; index < count; index += threadCount) {
        keys[index] = sharedKeys[index];
    }
}
kernel void buildLBVH(device const float4 *bounds [[buffer(0)]], device const uint2 *keys [[buffer(1)]], device float4 *tree [[buffer(2)]], constant uint &count [[buffer(3)]], constant uint &leafBase [[buffer(4)]], constant uint &levelStart [[buffer(5)]], constant uint &levelCount [[buffer(6)]], uint index [[thread_position_in_grid]]) { if (index >= levelCount) { return; } const uint node = levelStart + index; if (node >= leafBase) { const uint sorted = node - leafBase; tree[node] = sorted < count ? bounds[keys[sorted].y] : float4(INFINITY, INFINITY, -INFINITY, -INFINITY); } else { const float4 left = tree[node * 2]; const float4 right = tree[node * 2 + 1]; tree[node] = float4(min(left.xy, right.xy), max(left.zw, right.zw)); } }
kernel void emitCandidatePairs(
    device const float4 *bounds [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device const uint2 *keys [[buffer(2)]],
    device uint2 *pairs [[buffer(3)]],
    device atomic_uint *pairCount [[buffer(4)]],
    device atomic_uint *comparisonCount [[buffer(5)]],
    constant uint &count [[buffer(6)]],
    constant uint &capacity [[buffer(7)]],
    uint first [[thread_position_in_grid]]
) {
    if (first >= count) { return; }
    const uint firstIndex = keys[first].y;
    const float4 a = bounds[firstIndex];
    for (uint second = first + 1; second < count; ++second) {
        atomic_fetch_add_explicit(comparisonCount, 1u, memory_order_relaxed);
        const uint secondIndex = keys[second].y;
        const float4 b = bounds[secondIndex];
        if (b.x > a.z) { break; }
        if (a.y > b.w || a.w < b.y) { continue; }
        const uint slot = atomic_fetch_add_explicit(pairCount, 1u, memory_order_relaxed);
        if (slot < capacity) {
            pairs[slot] = uint2(ranges[firstIndex].id, ranges[secondIndex].id);
        }
    }
}
