#include <metal_stdlib>
using namespace metal;

struct MetalCorrection { uint particleIndex; uint sourceIndex; float2 delta; };
struct MetalContactPairWork { uint first; uint second; uint correctionStart; uint padding; };
struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalBubbleRange { uint id; uint centerIndex; uint boundaryStart; uint boundaryCount; float restArea; uint distanceConstraintStart; uint distanceConstraintCount; float padding; };

kernel void generateBubbleContacts(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device const MetalContactPairWork *pairs [[buffer(2)]],
    device MetalCorrection *corrections [[buffer(3)]],
    constant uint &pairCount [[buffer(4)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    if (pairIndex >= pairCount) { return; }
    const MetalContactPairWork pair = pairs[pairIndex];
    const MetalBubbleRange first = ranges[pair.first];
    const MetalBubbleRange second = ranges[pair.second];
    const float2 firstCenter = particles[first.centerIndex].position;
    const float2 secondCenter = particles[second.centerIndex].position;
    const float2 separation = secondCenter - firstCenter;
    const float distance = length(separation);
    const float firstRadius = sqrt(first.restArea / M_PI_F);
    const float secondRadius = sqrt(second.restArea / M_PI_F);
    const float penetration = firstRadius + secondRadius - distance;
    corrections[pair.correctionStart] = { first.centerIndex, pair.correctionStart, float2(0.0f) };
    corrections[pair.correctionStart + 1] = { second.centerIndex, pair.correctionStart + 1, float2(0.0f) };
    for (uint offset = 0; offset < first.boundaryCount; ++offset) {
        const uint slot = pair.correctionStart + 2 + offset;
        corrections[slot] = { first.boundaryStart + offset, slot, float2(0.0f) };
    }
    for (uint offset = 0; offset < second.boundaryCount; ++offset) {
        const uint slot = pair.correctionStart + 2 + first.boundaryCount + offset;
        corrections[slot] = { second.boundaryStart + offset, slot, float2(0.0f) };
    }
    if (penetration <= 0.0f) { return; }
    const float2 normal = distance > 0.00001f ? separation / distance : float2(1.0f, 0.0f);
    MetalCorrection firstCenterCorrection = { first.centerIndex, pair.correctionStart, -normal * penetration * 0.5f };
    corrections[pair.correctionStart] = firstCenterCorrection;
    MetalCorrection secondCenterCorrection = { second.centerIndex, pair.correctionStart + 1, normal * penetration * 0.5f };
    corrections[pair.correctionStart + 1] = secondCenterCorrection;
    for (uint offset = 0; offset < first.boundaryCount; ++offset) {
        const uint particle = first.boundaryStart + offset;
        const float2 radial = particles[particle].position - secondCenter;
        const float radialLength = length(radial);
        const uint slot = pair.correctionStart + 2 + offset;
        if (radialLength >= secondRadius) { corrections[slot] = { particle, slot, float2(0.0f) }; continue; }
        const float2 delta = (radialLength > 0.00001f ? radial / radialLength : -normal) * (secondRadius - radialLength + 0.01f);
        corrections[slot] = { particle, slot, delta };
    }
    for (uint offset = 0; offset < second.boundaryCount; ++offset) {
        const uint particle = second.boundaryStart + offset;
        const float2 radial = particles[particle].position - firstCenter;
        const float radialLength = length(radial);
        const uint slot = pair.correctionStart + 2 + first.boundaryCount + offset;
        if (radialLength >= firstRadius) { corrections[slot] = { particle, slot, float2(0.0f) }; continue; }
        const float2 delta = (radialLength > 0.00001f ? radial / radialLength : normal) * (firstRadius - radialLength + 0.01f);
        corrections[slot] = { particle, slot, delta };
    }
}

kernel void gatherCorrections(
    device const MetalCorrection *source [[buffer(0)]],
    device const uint *sourceIndices [[buffer(1)]],
    device MetalCorrection *sorted [[buffer(2)]],
    constant uint &count [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    if (index < count) { sorted[index] = source[sourceIndices[index]]; }
}

kernel void sortCorrectionsByParticle(device MetalCorrection *corrections [[buffer(0)]], constant uint &count [[buffer(1)]], constant uint &stage [[buffer(2)]], constant uint &stride [[buffer(3)]], uint index [[thread_position_in_grid]]) {
    const uint partner = index ^ stride;
    if (index >= count || partner >= count || partner <= index) { return; }
    const bool ascending = (index & stage) == 0;
    const MetalCorrection a = corrections[index]; const MetalCorrection b = corrections[partner];
    const bool greater = a.particleIndex != b.particleIndex ? a.particleIndex > b.particleIndex : a.sourceIndex > b.sourceIndex;
    const bool less = a.particleIndex != b.particleIndex ? a.particleIndex < b.particleIndex : a.sourceIndex < b.sourceIndex;
    if ((ascending && greater) || (!ascending && less)) { corrections[index] = b; corrections[partner] = a; }
}

kernel void reduceCorrections(
    device const MetalCorrection *corrections [[buffer(0)]],
    device float2 *reduced [[buffer(1)]], constant uint &correctionCount [[buffer(2)]], uint index [[thread_position_in_grid]]
) {
    if (index >= correctionCount) { return; }
    const uint particleIndex = corrections[index].particleIndex;
    if (particleIndex == UINT_MAX || (index > 0 && corrections[index - 1].particleIndex == particleIndex)) { return; }
    float2 sum = float2(0.0f);
    for (uint cursor = index; cursor < correctionCount && corrections[cursor].particleIndex == particleIndex; ++cursor) {
        sum += corrections[cursor].delta;
    }
    reduced[particleIndex] = sum;
}

kernel void applyCorrections(
    device MetalParticle *particles [[buffer(0)]],
    device float2 *reduced [[buffer(1)]],
    constant uint &particleCount [[buffer(2)]],
    uint particleIndex [[thread_position_in_grid]]
) {
    if (particleIndex >= particleCount) { return; }
    particles[particleIndex].position += reduced[particleIndex];
    particles[particleIndex].previousPosition += reduced[particleIndex];
    reduced[particleIndex] = float2(0.0f);
}

kernel void applyGatheredCorrections(
    device const MetalCorrection *corrections [[buffer(0)]],
    device const uint *sourceIndices [[buffer(1)]],
    device const uint2 *particleRanges [[buffer(2)]],
    device MetalParticle *particles [[buffer(3)]],
    constant uint &particleCount [[buffer(4)]],
    uint particleIndex [[thread_position_in_grid]]
) {
    if (particleIndex >= particleCount) { return; }
    const uint2 range = particleRanges[particleIndex];
    float2 sum = float2(0.0f);
    for (uint offset = 0; offset < range.y; ++offset) {
        sum += corrections[sourceIndices[range.x + offset]].delta;
    }
    particles[particleIndex].position += sum;
    particles[particleIndex].previousPosition += sum;
}
