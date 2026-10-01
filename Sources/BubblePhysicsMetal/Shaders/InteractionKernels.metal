#include <metal_stdlib>
using namespace metal;

struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalBubbleRange { uint id; uint centerIndex; uint boundaryStart; uint boundaryCount; float restArea; uint distanceConstraintStart; uint distanceConstraintCount; uint padding; };
struct MetalGrab { uint particleIndex; uint padding; float2 target; float maximumCorrection; float3 trailingPadding; };

kernel void pickBubble(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device uint2 *result [[buffer(2)]],
    constant float2 &point [[buffer(3)]],
    constant uint &bubbleCount [[buffer(4)]],
    uint threadIndex [[thread_position_in_grid]]
) {
    if (threadIndex != 0) { return; }
    uint2 selection = uint2(UINT_MAX, UINT_MAX);
    for (uint bubbleIndex = 0; bubbleIndex < bubbleCount; ++bubbleIndex) {
        const MetalBubbleRange range = ranges[bubbleIndex];
        bool inside = false;
        float nearestSquared = INFINITY;
        uint nearest = UINT_MAX;
        for (uint offset = 0; offset < range.boundaryCount; ++offset) {
            const uint currentIndex = range.boundaryStart + offset;
            const uint nextIndex = range.boundaryStart + (offset + 1) % range.boundaryCount;
            const float2 current = particles[currentIndex].position;
            const float2 next = particles[nextIndex].position;
            if ((current.y > point.y) != (next.y > point.y)) {
                const float crossing = (next.x - current.x) * (point.y - current.y) / (next.y - current.y) + current.x;
                if (point.x < crossing) { inside = !inside; }
            }
            const float distanceSquared = length_squared(current - point);
            if (distanceSquared < nearestSquared) { nearestSquared = distanceSquared; nearest = currentIndex; }
        }
        if (inside) { selection = uint2(range.id, nearest); }
    }
    result[0] = selection;
}

kernel void applyResistantGrab(
    device MetalParticle *particles [[buffer(0)]],
    device const MetalGrab *grab [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) { return; }
    const MetalGrab value = grab[0];
    MetalParticle particle = particles[value.particleIndex];
    const float2 delta = value.target - particle.position;
    const float distance = length(delta);
    if (distance > 0.0f) {
        particle.position += delta / distance * min(distance, value.maximumCorrection);
        particles[value.particleIndex] = particle;
    }
}
