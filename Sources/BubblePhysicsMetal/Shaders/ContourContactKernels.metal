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
