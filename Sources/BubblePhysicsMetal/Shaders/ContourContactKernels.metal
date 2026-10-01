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
struct AtomicCorrection { atomic_int x; atomic_int y; atomic_uint count; uint padding; };
constant float correctionFixedPointScale = 4096.0f;
constant float maximumContactCorrectionPerIteration = 4.0f;

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

kernel void resetAtomicContourContactGeneration(
    device atomic_uint &contactCount [[buffer(0)]],
    device atomic_uint &overflow [[buffer(1)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) { return; }
    atomic_store_explicit(&contactCount, 0u, memory_order_relaxed);
    atomic_store_explicit(&overflow, 0u, memory_order_relaxed);
}

kernel void resetPairContactFlags(
    device atomic_uint *pairContactFlags [[buffer(0)]],
    constant uint &pairCapacity [[buffer(1)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    if (pairIndex < pairCapacity) { atomic_store_explicit(&pairContactFlags[pairIndex], 0u, memory_order_relaxed); }
}

void appendContourContact(
    MetalContourContact contact,
    device MetalContourContact *contacts,
    device atomic_uint &contactCount,
    device atomic_uint &overflow,
    uint capacity
) {
    const uint slot = atomic_fetch_add_explicit(&contactCount, 1u, memory_order_relaxed);
    if (slot < capacity) { contacts[slot] = contact; }
    else { atomic_store_explicit(&overflow, 1u, memory_order_relaxed); }
}

kernel void generateContourContactsAtomic(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device const uint2 *pairs [[buffer(2)]],
    device const atomic_uint &pairCount [[buffer(3)]],
    device MetalContourContact *contacts [[buffer(4)]],
    device atomic_uint &contactCount [[buffer(5)]],
    device atomic_uint &overflow [[buffer(6)]],
    constant uint &pairCapacity [[buffer(7)]],
    constant uint &contactCapacity [[buffer(8)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    if (pairIndex >= min(atomic_load_explicit(&pairCount, memory_order_relaxed), pairCapacity)) { return; }
    const uint2 pair = pairs[pairIndex];
    const MetalBubbleRange first = ranges[pair.x], second = ranges[pair.y];
    for (uint point = 0; point < first.boundaryCount; ++point) {
        const uint pointIndex = first.boundaryStart + point;
        if (pointInside(particles[pointIndex].position, second, particles)) {
            appendContourContact(pointEdgeContact(pointIndex, second, pairIndex, 0, point, particles), contacts, contactCount, overflow, contactCapacity);
        }
    }
    for (uint point = 0; point < second.boundaryCount; ++point) {
        const uint pointIndex = second.boundaryStart + point;
        if (pointInside(particles[pointIndex].position, first, particles)) {
            appendContourContact(pointEdgeContact(pointIndex, first, pairIndex, 1, point, particles), contacts, contactCount, overflow, contactCapacity);
        }
    }
    for (uint a = 0; a < first.boundaryCount; ++a) {
        const uint aNext = (a + 1) % first.boundaryCount;
        const float2 a0 = particles[first.boundaryStart + a].position;
        const float2 a1 = particles[first.boundaryStart + aNext].position;
        for (uint b = 0; b < second.boundaryCount; ++b) {
            float t;
            if (!edgeIntersection(a0, a1, particles[second.boundaryStart + b].position, particles[second.boundaryStart + (b + 1) % second.boundaryCount].position, t)) { continue; }
            const float2 intersection = mix(particles[second.boundaryStart + b].position, particles[second.boundaryStart + (b + 1) % second.boundaryCount].position, t);
            const bool useStart = dot(a0 - intersection, a0 - intersection) <= dot(a1 - intersection, a1 - intersection);
            const uint pointIndex = first.boundaryStart + (useStart ? a : aNext);
            MetalContourContact contact = pointEdgeContact(pointIndex, second, pairIndex, 2, a * second.boundaryCount + b, particles);
            contact.penetration += 0.01f;
            appendContourContact(contact, contacts, contactCount, overflow, contactCapacity);
        }
    }
}

kernel void prepareContourPointDispatch(
    device const atomic_uint &pairCount [[buffer(0)]],
    device uint *arguments [[buffer(1)]],
    constant uint &pairCapacity [[buffer(2)]],
    constant uint &maximumBoundaryCount [[buffer(3)]],
    constant uint &threadsPerThreadgroup [[buffer(4)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) { return; }
    const uint pairs = min(atomic_load_explicit(&pairCount, memory_order_relaxed), pairCapacity);
    const uint workItems = pairs * maximumBoundaryCount * 2u;
    arguments[0] = (workItems + threadsPerThreadgroup - 1u) / threadsPerThreadgroup;
    arguments[1] = 1u;
    arguments[2] = 1u;
}

kernel void generateContourPointContacts(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device const uint2 *pairs [[buffer(2)]],
    device const atomic_uint &pairCount [[buffer(3)]],
    device MetalContourContact *contacts [[buffer(4)]],
    device atomic_uint &contactCount [[buffer(5)]],
    device atomic_uint &overflow [[buffer(6)]],
    constant uint &pairCapacity [[buffer(7)]],
    constant uint &contactCapacity [[buffer(8)]],
    constant uint &maximumBoundaryCount [[buffer(9)]],
    device atomic_uint *pairContactFlags [[buffer(10)]],
    uint workIndex [[thread_position_in_grid]]
) {
    const uint workPerPair = maximumBoundaryCount * 2u;
    const uint pairIndex = workIndex / workPerPair;
    if (pairIndex >= min(atomic_load_explicit(&pairCount, memory_order_relaxed), pairCapacity)) { return; }
    const uint local = workIndex - pairIndex * workPerPair;
    const uint direction = local / maximumBoundaryCount;
    const uint point = local - direction * maximumBoundaryCount;
    const uint2 pair = pairs[pairIndex];
    const MetalBubbleRange pointRange = direction == 0 ? ranges[pair.x] : ranges[pair.y];
    const MetalBubbleRange edgeRange = direction == 0 ? ranges[pair.y] : ranges[pair.x];
    if (point >= pointRange.boundaryCount) { return; }
    const uint pointIndex = pointRange.boundaryStart + point;
    if (!pointInside(particles[pointIndex].position, edgeRange, particles)) { return; }
    atomic_store_explicit(&pairContactFlags[pairIndex], 1u, memory_order_relaxed);
    appendContourContact(
        pointEdgeContact(pointIndex, edgeRange, pairIndex, direction, point, particles),
        contacts, contactCount, overflow, contactCapacity
    );
}

kernel void generateCrossingContactsForEmptyPairs(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *ranges [[buffer(1)]],
    device const uint2 *pairs [[buffer(2)]],
    device const atomic_uint &pairCount [[buffer(3)]],
    device MetalContourContact *contacts [[buffer(4)]],
    device atomic_uint &contactCount [[buffer(5)]],
    device atomic_uint &overflow [[buffer(6)]],
    constant uint &pairCapacity [[buffer(7)]],
    constant uint &contactCapacity [[buffer(8)]],
    device const atomic_uint *pairContactFlags [[buffer(9)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    if (pairIndex >= min(atomic_load_explicit(&pairCount, memory_order_relaxed), pairCapacity) ||
        atomic_load_explicit(&pairContactFlags[pairIndex], memory_order_relaxed) != 0u) { return; }
    const uint2 pair = pairs[pairIndex];
    const MetalBubbleRange first = ranges[pair.x], second = ranges[pair.y];
    for (uint a = 0; a < first.boundaryCount; ++a) {
        const uint aNext = (a + 1) % first.boundaryCount;
        const float2 a0 = particles[first.boundaryStart + a].position;
        const float2 a1 = particles[first.boundaryStart + aNext].position;
        for (uint b = 0; b < second.boundaryCount; ++b) {
            float t;
            if (!edgeIntersection(a0, a1, particles[second.boundaryStart + b].position,
                                  particles[second.boundaryStart + (b + 1) % second.boundaryCount].position, t)) { continue; }
            const float2 crossing = mix(particles[second.boundaryStart + b].position,
                                        particles[second.boundaryStart + (b + 1) % second.boundaryCount].position, t);
            const bool useStart = dot(a0 - crossing, a0 - crossing) <= dot(a1 - crossing, a1 - crossing);
            MetalContourContact contact = pointEdgeContact(first.boundaryStart + (useStart ? a : aNext), second,
                                                           pairIndex, 2u, a * second.boundaryCount + b, particles);
            contact.penetration += 0.01f;
            appendContourContact(contact, contacts, contactCount, overflow, contactCapacity);
        }
    }
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

kernel void resetAtomicContourCorrections(
    device AtomicCorrection *corrections [[buffer(0)]],
    constant uint &particleCount [[buffer(1)]],
    uint particleIndex [[thread_position_in_grid]]
) {
    if (particleIndex >= particleCount) { return; }
    atomic_store_explicit(&corrections[particleIndex].x, 0, memory_order_relaxed);
    atomic_store_explicit(&corrections[particleIndex].y, 0, memory_order_relaxed);
    atomic_store_explicit(&corrections[particleIndex].count, 0u, memory_order_relaxed);
}

void addAtomicCorrection(device AtomicCorrection *corrections, uint particleIndex, float2 delta) {
    const int2 encoded = int2(round(delta * correctionFixedPointScale));
    atomic_fetch_add_explicit(&corrections[particleIndex].x, encoded.x, memory_order_relaxed);
    atomic_fetch_add_explicit(&corrections[particleIndex].y, encoded.y, memory_order_relaxed);
    atomic_fetch_add_explicit(&corrections[particleIndex].count, 1u, memory_order_relaxed);
}

kernel void accumulateContourContactCorrections(
    device const MetalParticle *particles [[buffer(0)]],
    device const MetalContourContact *contacts [[buffer(1)]],
    device const uint &contactCount [[buffer(2)]],
    device const uint &overflow [[buffer(3)]],
    device AtomicCorrection *corrections [[buffer(4)]],
    constant uint &contactCapacity [[buffer(5)]],
    uint contactIndex [[thread_position_in_grid]]
) {
    if (overflow != 0 || contactIndex >= min(contactCount, contactCapacity)) { return; }
    const MetalContourContact contact = contacts[contactIndex];
    const float t = contact.barycentric;
    const float wp = particles[contact.pointIndex].inverseMass;
    const float wa = particles[contact.edgeStartIndex].inverseMass;
    const float wb = particles[contact.edgeEndIndex].inverseMass;
    const float denominator = wp + wa * (1.0f - t) * (1.0f - t) + wb * t * t;
    if (denominator <= 1e-12f) { return; }
    const float scale = contact.penetration / denominator;
    addAtomicCorrection(corrections, contact.pointIndex, contact.normal * (wp * scale));
    addAtomicCorrection(corrections, contact.edgeStartIndex, -contact.normal * (wa * (1.0f - t) * scale));
    addAtomicCorrection(corrections, contact.edgeEndIndex, -contact.normal * (wb * t * scale));
}

kernel void applyAtomicContourCorrections(
    device MetalParticle *particles [[buffer(0)]],
    device AtomicCorrection *corrections [[buffer(1)]],
    constant uint &particleCount [[buffer(2)]],
    uint particleIndex [[thread_position_in_grid]]
) {
    if (particleIndex >= particleCount) { return; }
    const int x = atomic_load_explicit(&corrections[particleIndex].x, memory_order_relaxed);
    const int y = atomic_load_explicit(&corrections[particleIndex].y, memory_order_relaxed);
    const uint count = atomic_load_explicit(&corrections[particleIndex].count, memory_order_relaxed);
    if (count > 0u) {
        const float2 averaged = float2(x, y) / (correctionFixedPointScale * float(count));
        const float magnitude = length(averaged);
        particles[particleIndex].position += magnitude > maximumContactCorrectionPerIteration
            ? averaged * (maximumContactCorrectionPerIteration / magnitude)
            : averaged;
    }
}

kernel void solveContourSelfIntersections(
    device MetalParticle *particles [[buffer(0)]], device const MetalBubbleRange *ranges [[buffer(1)]],
    constant uint &bubbleCount [[buffer(2)]], uint bubbleIndex [[thread_position_in_grid]]
) {
    if (bubbleIndex >= bubbleCount) { return; }
    const MetalBubbleRange range = ranges[bubbleIndex];
    for (uint first = 0; first < range.boundaryCount; ++first) {
        const uint firstNext = (first + 1) % range.boundaryCount;
        for (uint second = first + 2; second < range.boundaryCount; ++second) {
            const uint secondNext = (second + 1) % range.boundaryCount;
            if (secondNext == first) { continue; }
            const uint a = range.boundaryStart + first, b = range.boundaryStart + firstNext;
            const uint c = range.boundaryStart + second, d = range.boundaryStart + secondNext;
            float t;
            if (!edgeIntersection(particles[a].position, particles[b].position, particles[c].position, particles[d].position, t)) { continue; }
            const float2 edge = particles[d].position - particles[c].position;
            const float edgeLength = length(edge); if (edgeLength <= 1e-7f) { continue; }
            float2 normal = float2(-edge.y, edge.x) / edgeLength;
            const float side = dot(particles[a].position - particles[c].position, normal);
            if (side < 0.0f) { normal = -normal; }
            const float correction = max(0.01f, edgeLength * 0.25f);
            particles[a].position += normal * correction;
            particles[b].position += normal * correction;
            particles[c].position -= normal * correction;
            particles[d].position -= normal * correction;
        }
    }
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
