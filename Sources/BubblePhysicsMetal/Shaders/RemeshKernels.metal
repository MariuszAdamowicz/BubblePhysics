#include <metal_stdlib>
using namespace metal;

struct RemeshVertex {
    float2 position;
    float2 previousPosition;
    float restLength;
    float stiffnessScale;
};

kernel void markRemeshEdges(
    device const RemeshVertex *vertices [[buffer(0)]],
    device int *marks [[buffer(1)]],
    constant uint &count [[buffer(2)]],
    constant float &splitLength [[buffer(3)]],
    constant float &mergeLength [[buffer(4)]],
    uint edge [[thread_position_in_grid]]
) {
    if (edge >= count) { return; }
    const uint next = (edge + 1) % count;
    const float currentLength = length(vertices[next].position - vertices[edge].position);
    marks[edge] = currentLength > splitLength ? 1 : (currentLength < mergeLength && count > 8 ? -1 : 0);
}

// Deterministically selects one material edit. This pass also performs the
// prefix/count decision before any destination record can be written.
kernel void prefixRemeshPlan(
    device const int *marks [[buffer(0)]],
    device int2 &action [[buffer(1)]],
    device uint &requiredCount [[buffer(2)]],
    device uint &capacityGrowthRequired [[buffer(3)]],
    constant uint &count [[buffer(4)]],
    constant uint &capacity [[buffer(5)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) { return; }
    action = int2(0, -1);
    for (uint edge = 0; edge < count; ++edge) {
        if (marks[edge] == 1) { action = int2(1, int(edge)); break; }
    }
    if (action.x == 0 && count > 8) {
        for (uint edge = 0; edge < count; ++edge) {
            if (marks[edge] == -1) { action = int2(-1, int(edge)); break; }
        }
    }
    requiredCount = action.x == 1 ? count + 1 : (action.x == -1 ? count - 1 : count);
    capacityGrowthRequired = requiredCount > capacity ? requiredCount : 0;
}

kernel void compactRemeshContour(
    device const RemeshVertex *source [[buffer(0)]],
    device RemeshVertex *destination [[buffer(1)]],
    device const int2 &action [[buffer(2)]],
    device const uint &requiredCount [[buffer(3)]],
    device const uint &capacityGrowthRequired [[buffer(4)]],
    constant uint &sourceCount [[buffer(5)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0 || capacityGrowthRequired != 0) { return; }
    if (action.x == 0) {
        for (uint i = 0; i < sourceCount; ++i) { destination[i] = source[i]; }
        return;
    }
    const uint edge = uint(action.y);
    if (action.x == 1) {
        uint output = 0;
        for (uint i = 0; i < sourceCount; ++i) {
            RemeshVertex current = source[i];
            if (i == edge) { current.restLength *= 0.5f; current.stiffnessScale *= 2.0f; }
            destination[output++] = current;
            if (i == edge) {
                const uint next = (i + 1) % sourceCount;
                RemeshVertex inserted;
                inserted.position = (source[i].position + source[next].position) * 0.5f;
                inserted.previousPosition = (source[i].previousPosition + source[next].previousPosition) * 0.5f;
                inserted.restLength = current.restLength;
                inserted.stiffnessScale = current.stiffnessScale;
                destination[output++] = inserted;
            }
        }
    } else {
        const uint removed = (edge + 1) % sourceCount;
        uint output = 0;
        for (uint i = 0; i < sourceCount; ++i) {
            if (i == removed) { continue; }
            RemeshVertex current = source[i];
            if (i == edge) {
                current.restLength += source[removed].restLength;
                current.stiffnessScale = min(current.stiffnessScale, source[removed].stiffnessScale) * 0.5f;
            }
            destination[output++] = current;
        }
    }
    (void)requiredCount;
}
