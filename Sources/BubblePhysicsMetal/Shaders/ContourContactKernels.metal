#include <metal_stdlib>
using namespace metal;

struct MetalContourContact {
    uint pointIndex;
    uint edgeStartIndex;
    uint edgeEndIndex;
    float barycentric;
    float2 normal;
    float penetration;
    uint padding;
    ulong sourceID;
    uint2 trailingPadding;
};
struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalBubbleRange { uint id; uint centerIndex; uint boundaryStart; uint boundaryCount; float restArea; uint springStart; uint springCount; float padding; };
struct MetalCorrection { uint particleIndex; uint sourceIndex; float2 delta; };

float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

bool pointInside(float2 point, MetalBubbleRange contour, device const MetalParticle *particles) {
    bool inside = false;
    for (uint edge = 0; edge < contour.boundaryCount; ++edge) {
        const float2 start = particles[contour.boundaryStart + edge].position;
        const float2 end = particles[contour.boundaryStart + (edge + 1) % contour.boundaryCount].position;
        const float2 segment = end - start;
        const float lengthSquared = dot(segment, segment);
        const float t = lengthSquared > 1e-12f ? clamp(dot(point - start, segment) / lengthSquared, 0.0f, 1.0f) : 0.0f;
        if (length(start + segment * t - point) <= 1e-6f) { return true; }
        if ((start.y > point.y) != (end.y > point.y)) {
            const float crossingX = (end.x - start.x) * (point.y - start.y) / (end.y - start.y) + start.x;
            if (point.x < crossingX) { inside = !inside; }
        }
    }
    return inside;
}

bool edgeIntersection(float2 a, float2 b, float2 c, float2 d, thread float &secondT) {
    const float2 first = b - a, second = d - c;
    const float denominator = cross2(first, second);
    if (abs(denominator) <= 1e-7f) { return false; }
    const float2 offset = c - a;
    const float firstT = cross2(offset, second) / denominator;
    secondT = cross2(offset, first) / denominator;
    return firstT >= 0.0f && firstT <= 1.0f && secondT >= 0.0f && secondT <= 1.0f;
}

kernel void countContourContactFeatures(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device const uint2 *pairs [[buffer(2)]],
    device const atomic_uint &pairCount [[buffer(3)]],
    device uint *sourceCounts [[buffer(4)]],
    constant uint &pairCapacity [[buffer(5)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    const uint base = pairIndex * 3;
    sourceCounts[base] = sourceCounts[base + 1] = sourceCounts[base + 2] = 0;
    if (pairIndex >= min(atomic_load_explicit(&pairCount, memory_order_relaxed), pairCapacity)) { return; }
    const uint2 pair = pairs[pairIndex];
    const MetalBubbleRange first = ranges[pair.x], second = ranges[pair.y];
    for (uint point = 0; point < first.boundaryCount; ++point) {
        sourceCounts[base] += pointInside(particles[first.boundaryStart + point].position, second, particles) ? 1u : 0u;
    }
    for (uint point = 0; point < second.boundaryCount; ++point) {
        sourceCounts[base + 1] += pointInside(particles[second.boundaryStart + point].position, first, particles) ? 1u : 0u;
    }
    for (uint a = 0; a < first.boundaryCount; ++a) {
        const float2 a0 = particles[first.boundaryStart + a].position;
        const float2 a1 = particles[first.boundaryStart + (a + 1) % first.boundaryCount].position;
        for (uint b = 0; b < second.boundaryCount; ++b) {
            float ignored;
            if (edgeIntersection(a0, a1, particles[second.boundaryStart + b].position, particles[second.boundaryStart + (b + 1) % second.boundaryCount].position, ignored)) { sourceCounts[base + 2] += 1u; }
        }
    }
}

MetalContourContact pointEdgeContact(uint pointIndex, MetalBubbleRange edgeRange, uint pairIndex, uint direction, uint feature, device const MetalParticle *particles) {
    const float2 point = particles[pointIndex].position;
    float bestDistance = INFINITY, bestT = 0.0f; uint bestEdge = 0; float2 bestDelta = float2(1.0f, 0.0f);
    for (uint edge = 0; edge < edgeRange.boundaryCount; ++edge) {
        const float2 start = particles[edgeRange.boundaryStart + edge].position;
        const float2 end = particles[edgeRange.boundaryStart + (edge + 1) % edgeRange.boundaryCount].position;
        const float2 segment = end - start; const float denominator = dot(segment, segment);
        const float t = denominator > 1e-12f ? clamp(dot(point - start, segment) / denominator, 0.0f, 1.0f) : 0.0f;
        const float2 delta = start + segment * t - point; const float distance = length(delta);
        if (distance < bestDistance) { bestDistance = distance; bestT = t; bestEdge = edge; bestDelta = delta; }
    }
    float2 normal = bestDistance > 1e-7f ? bestDelta / bestDistance : float2(1.0f, 0.0f);
    MetalContourContact output = { pointIndex, edgeRange.boundaryStart + bestEdge, edgeRange.boundaryStart + (bestEdge + 1) % edgeRange.boundaryCount, bestT, normal, bestDistance, 0u, (ulong(pairIndex) << 32) | (ulong(direction) << 28) | ulong(feature), uint2(0) };
    return output;
}

kernel void writeContourContactFeatures(
    device const MetalParticle *particles [[buffer(0)]], device const MetalBubbleRange *ranges [[buffer(1)]],
    device const uint2 *pairs [[buffer(2)]], device const atomic_uint &pairCount [[buffer(3)]],
    device const uint *sourceOffsets [[buffer(4)]], device const uint &overflow [[buffer(5)]],
    device MetalContourContact *contacts [[buffer(6)]], constant uint &pairCapacity [[buffer(7)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    if (overflow != 0 || pairIndex >= min(atomic_load_explicit(&pairCount, memory_order_relaxed), pairCapacity)) { return; }
    const uint2 pair = pairs[pairIndex]; const MetalBubbleRange first = ranges[pair.x], second = ranges[pair.y];
    uint firstCursor = sourceOffsets[pairIndex * 3], secondCursor = sourceOffsets[pairIndex * 3 + 1], crossingCursor = sourceOffsets[pairIndex * 3 + 2];
    for (uint point = 0; point < first.boundaryCount; ++point) if (pointInside(particles[first.boundaryStart + point].position, second, particles)) {
        contacts[firstCursor++] = pointEdgeContact(first.boundaryStart + point, second, pairIndex, 0, point, particles);
    }
    for (uint point = 0; point < second.boundaryCount; ++point) if (pointInside(particles[second.boundaryStart + point].position, first, particles)) {
        contacts[secondCursor++] = pointEdgeContact(second.boundaryStart + point, first, pairIndex, 1, point, particles);
    }
    for (uint a = 0; a < first.boundaryCount; ++a) {
        const uint aNext = (a + 1) % first.boundaryCount; const float2 a0 = particles[first.boundaryStart + a].position, a1 = particles[first.boundaryStart + aNext].position;
        for (uint b = 0; b < second.boundaryCount; ++b) { float t;
            if (!edgeIntersection(a0, a1, particles[second.boundaryStart + b].position, particles[second.boundaryStart + (b + 1) % second.boundaryCount].position, t)) { continue; }
            const float2 intersection = mix(particles[second.boundaryStart + b].position, particles[second.boundaryStart + (b + 1) % second.boundaryCount].position, t);
            const bool useStart = dot(a0 - intersection, a0 - intersection) <= dot(a1 - intersection, a1 - intersection); const uint pointIndex = first.boundaryStart + (useStart ? a : aNext);
            MetalContourContact contact = pointEdgeContact(pointIndex, second, pairIndex, 2, a * second.boundaryCount + b, particles); contact.penetration += 0.01f; contacts[crossingCursor++] = contact;
        }
    }
}

kernel void solveContourContactCorrections(
    device const MetalParticle *particles [[buffer(0)]], device const MetalContourContact *contacts [[buffer(1)]],
    device const uint &contactCount [[buffer(2)]], device MetalCorrection *corrections [[buffer(3)]],
    constant uint &correctionCapacity [[buffer(4)]], uint contactIndex [[thread_position_in_grid]]
) {
    if (contactIndex >= contactCount || contactIndex * 3 + 2 >= correctionCapacity) { return; }
    const MetalContourContact contact = contacts[contactIndex]; const float t = contact.barycentric;
    const float wp = particles[contact.pointIndex].inverseMass, wa = particles[contact.edgeStartIndex].inverseMass, wb = particles[contact.edgeEndIndex].inverseMass;
    const float denominator = wp + wa * (1.0f - t) * (1.0f - t) + wb * t * t;
    const float scale = denominator > 1e-12f ? contact.penetration / denominator : 0.0f; const uint base = contactIndex * 3;
    corrections[base] = { contact.pointIndex, base, contact.normal * (wp * scale) };
    corrections[base + 1] = { contact.edgeStartIndex, base + 1, -contact.normal * (wa * (1.0f - t) * scale) };
    corrections[base + 2] = { contact.edgeEndIndex, base + 2, -contact.normal * (wb * t * scale) };
}

kernel void applyContourCorrections(
    device MetalParticle *particles [[buffer(0)]], device const MetalCorrection *corrections [[buffer(1)]],
    device const uint &contactCount [[buffer(2)]], constant uint &particleCount [[buffer(3)]],
    uint particleIndex [[thread_position_in_grid]]
) {
    if (particleIndex >= particleCount) { return; }
    float2 total = float2(0.0f); const uint correctionCount = contactCount * 3;
    for (uint index = 0; index < correctionCount; ++index) {
        if (corrections[index].particleIndex == particleIndex) { total += corrections[index].delta; }
    }
    particles[particleIndex].position += total;
}

// One thread reserves all deterministic (pair, direction, feature) ranges.
// No writer is allowed to run when overflow is set, so a pair is never partial.
kernel void reserveContourContactRanges(
    device const uint *sourceCounts [[buffer(0)]],
    device uint *sourceOffsets [[buffer(1)]],
    device uint &totalCount [[buffer(2)]],
    device uint &overflow [[buffer(3)]],
    constant uint &sourceCount [[buffer(4)]],
    constant uint &capacity [[buffer(5)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) { return; }
    uint cursor = 0;
    sourceOffsets[0] = 0;
    for (uint source = 0; source < sourceCount; ++source) {
        cursor += sourceCounts[source];
        sourceOffsets[source + 1] = cursor;
    }
    totalCount = cursor;
    overflow = cursor > capacity ? 1u : 0u;
}

kernel void writeReservedContourContacts(
    device const MetalContourContact *candidates [[buffer(0)]],
    device MetalContourContact *contacts [[buffer(1)]],
    device const uint &totalCount [[buffer(2)]],
    device const uint &overflow [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    if (overflow != 0 || index >= totalCount) { return; }
    contacts[index] = candidates[index];
}
