#include <metal_stdlib>
using namespace metal;

struct MetalCorrection { uint particleIndex; float2 delta; };
struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalBubbleRange { uint id; uint centerIndex; uint boundaryStart; uint boundaryCount; float restArea; uint distanceConstraintStart; uint distanceConstraintCount; float padding; };

kernel void generateBubbleContacts(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device const uint2 *pairs [[buffer(2)]],
    device MetalCorrection *corrections [[buffer(3)]],
    device atomic_uint *correctionCount [[buffer(4)]],
    constant uint &pairCount [[buffer(5)]],
    constant uint &capacity [[buffer(6)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    if (pairIndex >= pairCount) { return; }
    const uint2 pair = pairs[pairIndex];
    const MetalBubbleRange first = ranges[pair.x];
    const MetalBubbleRange second = ranges[pair.y];
    const float2 firstCenter = particles[first.centerIndex].position;
    const float2 secondCenter = particles[second.centerIndex].position;
    const float2 separation = secondCenter - firstCenter;
    const float distance = length(separation);
    const float firstRadius = sqrt(first.restArea / M_PI_F);
    const float secondRadius = sqrt(second.restArea / M_PI_F);
    const float penetration = firstRadius + secondRadius - distance;
    if (penetration <= 0.0f) { return; }
    const float2 normal = distance > 0.00001f ? separation / distance : float2(1.0f, 0.0f);
    const float2 firstDelta = -normal * penetration * 0.5f;
    const float2 secondDelta = normal * penetration * 0.5f;
    for (uint offset = 0; offset <= first.boundaryCount; ++offset) {
        const uint particle = offset == 0 ? first.centerIndex : first.boundaryStart + offset - 1;
        const uint slot = atomic_fetch_add_explicit(correctionCount, 1u, memory_order_relaxed);
        if (slot < capacity) { corrections[slot] = { particle, firstDelta }; }
    }
    for (uint offset = 0; offset <= second.boundaryCount; ++offset) {
        const uint particle = offset == 0 ? second.centerIndex : second.boundaryStart + offset - 1;
        const uint slot = atomic_fetch_add_explicit(correctionCount, 1u, memory_order_relaxed);
        if (slot < capacity) { corrections[slot] = { particle, secondDelta }; }
    }
}

kernel void reduceCorrections(
    device const MetalCorrection *corrections [[buffer(0)]],
    device float2 *reduced [[buffer(1)]],
    constant uint &correctionCount [[buffer(2)]],
    constant uint &particleCount [[buffer(3)]],
    uint particleIndex [[thread_position_in_grid]]
) {
    if (particleIndex >= particleCount) { return; }
    float2 sum = float2(0.0f);
    for (uint index = 0; index < correctionCount; ++index) {
        if (corrections[index].particleIndex == particleIndex) { sum += corrections[index].delta; }
    }
    reduced[particleIndex] = sum;
}

kernel void applyCorrections(
    device MetalParticle *particles [[buffer(0)]],
    device const float2 *reduced [[buffer(1)]],
    constant uint &particleCount [[buffer(2)]],
    uint particleIndex [[thread_position_in_grid]]
) {
    if (particleIndex >= particleCount) { return; }
    particles[particleIndex].position += reduced[particleIndex];
    particles[particleIndex].previousPosition += reduced[particleIndex];
}
