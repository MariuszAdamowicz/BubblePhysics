#include <metal_stdlib>
using namespace metal;

// Central differences amplify a fused multiply-add's changed rounding. Preserve
// the CPU reference's separate multiply/add operations, including in safe math.
#pragma clang fp contract(off)

// Mirrors the SIMD-only Swift ABI. Stable IDs are never narrowed to indices.
struct ReferenceMetalBubble {
    long2 identity;
    float4 physical;
    float4 angular;
};
struct ReferenceMetalContact {
    ulong2 identity;
    long2 bubbles;
    long2 segmentAndAge;
    float4 geometry;
    float4 timing;
    float4 compression;
    float4 response;
};
struct ReferenceOperatorParameters {
    uint4 counts; // bubbles, contacts, reserved, reserved
    float4 physics; // dt, stiffness, nonlinear stiffening, contact damping
    float4 drag; // global drag, reserved
};
constant float referenceMinimumMass = 0x1p-149f;
constant float referenceEpsilon = 1e-3f;

inline float referenceDot(float2 a, float2 b) { return a.x * b.x + a.y * b.y; }
inline float2 referenceNormalize(float2 v, float2 fallback) {
    float squared = referenceDot(v, v);
    return isfinite(squared) && squared > 0x1p-23f ? v / sqrt(squared) : fallback;
}
inline int referenceBubbleIndex(long id, device const ReferenceMetalBubble *bubbles, uint count) {
    uint low = 0, high = count;
    while (low < high) {
        uint middle = low + (high - low) / 2;
        if (bubbles[middle].identity.x < id) low = middle + 1;
        else high = middle;
    }
    return low < count && bubbles[low].identity.x == id ? int(low) : -1;
}
inline float referenceEffectiveMass(float a, float b, bool hasB) {
    a = max(a, referenceMinimumMass);
    b = max(b, referenceMinimumMass);
    return hasB ? (a * b) / (a + b) : a;
}
inline float2 referenceEnd(uint i, device const float2 *end, device const float2 *vector, float shift) {
    return shift == 0 ? end[i] : end[i] + vector[i] * shift;
}
inline float2 referenceEndVelocity(uint i, device const float2 *start, device const float2 *velocity,
                                  device const float2 *end, device const float2 *vector,
                                  float shift, float dt) {
    return (referenceEnd(i, end, vector, shift) - start[i]) * (2 / dt) - velocity[i];
}
inline float2 referenceMidVelocity(uint i, device const float2 *start, device const float2 *velocity,
                                  device const float2 *end, device const float2 *vector,
                                  float shift, float dt) {
    return (velocity[i] + referenceEndVelocity(i, start, velocity, end, vector, shift, dt)) * 0.5f;
}
inline float2 referenceResidual(uint i, device const ReferenceMetalBubble *bubbles,
    device const float2 *start, device const float2 *velocity, device const ReferenceMetalContact *contacts,
    device const float2 *end, device const float2 *vector, ReferenceOperatorParameters p, float shift) {
    float dt = p.physics.x;
    float mass = max(bubbles[i].physical.x, referenceMinimumMass);
    float2 force = -referenceMidVelocity(i, start, velocity, end, vector, shift, dt) * (max(0.0f, p.drag.x) * mass);
    // Each row gathers contacts in stable contact-ID order, avoiding atomic sums.
    for (uint c = 0; c < p.counts.y; ++c) {
        ReferenceMetalContact contact = contacts[c];
        int a = referenceBubbleIndex(contact.bubbles.x, bubbles, p.counts.x);
        if (a < 0) continue;
        int b = (contact.identity.y & 2) ? referenceBubbleIndex(contact.bubbles.y, bubbles, p.counts.x) : -1;
        if (i != uint(a) && (b < 0 || i != uint(b))) continue;
        float2 centerA = (start[a] + referenceEnd(a, end, vector, shift)) * 0.5f;
        float2 anchor = b >= 0 ? (start[b] + referenceEnd(b, end, vector, shift)) * 0.5f : contact.geometry.zw;
        float2 offset = centerA - anchor;
        float2 fallback = referenceNormalize(b >= 0 ? -contact.geometry.xy : contact.geometry.xy, float2(1, 0));
        float2 normal = referenceNormalize(offset, fallback);
        if (b < 0 && referenceDot(normal, fallback) < 0) normal = fallback;
        float distance = bubbles[a].physical.z + (b >= 0 ? bubbles[b].physical.z : 0);
        float compression = max(0.0f, distance - sqrt(referenceDot(offset, offset)));
        if (compression <= 0) continue;
        float effectiveMass = referenceEffectiveMass(bubbles[a].physical.x, b >= 0 ? bubbles[b].physical.x : 0, b >= 0);
        float2 relativeVelocity = referenceMidVelocity(a, start, velocity, end, vector, shift, dt)
            - (b >= 0 ? referenceMidVelocity(b, start, velocity, end, vector, shift, dt) : float2(0));
        float normalizedCompression = compression / max(distance, referenceMinimumMass);
        float elastic = (max(0.0f, p.physics.y) * effectiveMass) * compression
            * (1 + max(0.0f, p.physics.z) * normalizedCompression * normalizedCompression);
        float damping = (max(0.0f, p.physics.w) * effectiveMass) * referenceDot(relativeVelocity, normal);
        float2 contactForce = normal * max(0.0f, elastic - damping);
        if (i == uint(a)) force += contactForce;
        if (b >= 0 && i == uint(b)) force -= contactForce;
    }
    return (referenceEndVelocity(i, start, velocity, end, vector, shift, dt) - velocity[i]) * mass - force * dt;
}

kernel void referenceBuildResidual(device const ReferenceMetalBubble *bubbles [[buffer(0)]],
    device const float2 *start [[buffer(1)]], device const float2 *velocity [[buffer(2)]],
    device const ReferenceMetalContact *contacts [[buffer(3)]], device const float2 *end [[buffer(4)]],
    device const float2 *vector [[buffer(5)]], device float2 *output [[buffer(6)]],
    constant ReferenceOperatorParameters &p [[buffer(7)]], uint i [[thread_position_in_grid]]) {
    if (i < p.counts.x) output[i] = referenceResidual(i, bubbles, start, velocity, contacts, end, vector, p, 0);
}

kernel void referenceApplyJacobian(device const ReferenceMetalBubble *bubbles [[buffer(0)]],
    device const float2 *start [[buffer(1)]], device const float2 *velocity [[buffer(2)]],
    device const ReferenceMetalContact *contacts [[buffer(3)]], device const float2 *end [[buffer(4)]],
    device const float2 *vector [[buffer(5)]], device float2 *output [[buffer(6)]],
    constant ReferenceOperatorParameters &p [[buffer(7)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.counts.x) return;
    // Match the CPU's global zero-vector guard, including lengthSquared underflow.
    bool nonzero = false;
    for (uint j = 0; j < p.counts.x; ++j) {
        if (referenceDot(vector[j], vector[j]) > 0) { nonzero = true; break; }
    }
    if (!nonzero) { output[i] = float2(0); return; }
    float2 plus = referenceResidual(i, bubbles, start, velocity, contacts, end, vector, p, referenceEpsilon);
    float2 minus = referenceResidual(i, bubbles, start, velocity, contacts, end, vector, p, -referenceEpsilon);
    output[i] = (plus - minus) / (2 * referenceEpsilon);
}

kernel void referenceBuildInverseDiagonal(device const ReferenceMetalBubble *bubbles [[buffer(0)]],
    device const float2 *start [[buffer(1)]], device const float2 *velocity [[buffer(2)]],
    device const ReferenceMetalContact *contacts [[buffer(3)]], device const float2 *end [[buffer(4)]],
    device const float2 *vector [[buffer(5)]], device float2 *output [[buffer(6)]],
    constant ReferenceOperatorParameters &p [[buffer(7)]], uint i [[thread_position_in_grid]]) {
    if (i >= p.counts.x) return;
    float diagonal = max(bubbles[i].physical.x, referenceMinimumMass) * (2 / p.physics.x + max(0.0f, p.drag.x));
    for (uint c = 0; c < p.counts.y; ++c) {
        ReferenceMetalContact contact = contacts[c];
        int a = referenceBubbleIndex(contact.bubbles.x, bubbles, p.counts.x);
        if (a < 0) continue;
        int b = (contact.identity.y & 2) ? referenceBubbleIndex(contact.bubbles.y, bubbles, p.counts.x) : -1;
        float mass = referenceEffectiveMass(bubbles[a].physical.x, b >= 0 ? bubbles[b].physical.x : 0, b >= 0);
        float contribution = p.physics.x * (max(0.0f, p.physics.y) * mass) * 0.5f + max(0.0f, p.physics.w) * mass;
        if (contribution > 0) {
            if (i == uint(a)) diagonal += contribution;
            if (b >= 0 && i == uint(b)) diagonal += contribution;
        }
    }
    output[i] = float2(1 / max(diagonal, referenceMinimumMass));
}

// First dispatch: 256-lane binary tree in each block, padding with exact zero.
// Second dispatch: one lane accumulates blocks in ascending order on the GPU.
kernel void referenceReduceDot(device const float2 *lhs [[buffer(0)]], device const float2 *rhs [[buffer(1)]],
    device float *blocks [[buffer(2)]], device float *result [[buffer(3)]],
    constant uint4 &p [[buffer(4)]], uint i [[thread_position_in_grid]],
    uint lane [[thread_index_in_threadgroup]], uint group [[threadgroup_position_in_grid]]) {
    if (p.z == 1) {
        if (i == 0) {
            float sum = 0;
            for (uint block = 0; block < p.y; ++block) sum += blocks[block];
            result[0] = sum;
        }
        return;
    }
    threadgroup float values[256];
    values[lane] = i < p.x ? referenceDot(lhs[i], rhs[i]) : 0;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint stride = 128; stride > 0; stride >>= 1) {
        if (lane < stride) values[lane] += values[lane + stride];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (lane == 0) blocks[group] = values[0];
}

struct ReferencePCGControl {
    uint4 state; // active, iterations, non-finite, rejected initial norm
    float4 norms; // initial, final, threshold, reserved
    float4 recurrence; // r·z, beta, reserved, reserved
};

// Norm and r·z accumulate in ascending row order, matching the CPU oracle.
// The operator denominator uses the fixed-block reduction above. No scalar is
// observed by the CPU until initialize/advance/direction/finalize all finish.
kernel void referencePCGInitialize(device const float2 *rhs [[buffer(0)]],
    device const float2 *diagonal [[buffer(1)]], device float2 *solution [[buffer(2)]],
    device float2 *residual [[buffer(3)]], device float2 *preconditioned [[buffer(4)]],
    device float2 *direction [[buffer(5)]], device ReferencePCGControl &control [[buffer(8)]],
    constant uint4 &counts [[buffer(9)]], constant float &tolerance [[buffer(10)]],
    uint lane [[thread_position_in_grid]]) {
    if (lane != 0) return;
    control.state = uint4(0);
    control.norms = float4(0);
    control.recurrence = float4(0);
    float squaredNorm = 0, rz = 0;
    bool finiteInput = true;
    for (uint i = 0; i < counts.x; ++i) {
        solution[i] = float2(0);
        residual[i] = rhs[i];
        preconditioned[i] = rhs[i] * diagonal[i];
        direction[i] = preconditioned[i];
        squaredNorm += referenceDot(residual[i], residual[i]);
        rz += referenceDot(residual[i], preconditioned[i]);
        finiteInput = finiteInput && all(isfinite(rhs[i]));
    }
    float initialNorm = sqrt(max(0.0f, squaredNorm));
    if (!finiteInput || !isfinite(squaredNorm) || !isfinite(initialNorm)) {
        control.state.z = 1;
        control.state.w = 1;
        return;
    }
    control.norms = float4(initialNorm, initialNorm, max(0.0f, tolerance) * initialNorm, 0);
    control.recurrence.x = rz;
    control.state.x = initialNorm > 0x1p-23f && counts.y > 0 ? 1 : 0;
}

kernel void referencePCGAdvance(device const float2 *diagonal [[buffer(1)]],
    device float2 *solution [[buffer(2)]], device float2 *residual [[buffer(3)]],
    device float2 *preconditioned [[buffer(4)]], device const float2 *direction [[buffer(5)]],
    device const float2 *applied [[buffer(6)]], device const float *denominator [[buffer(7)]],
    device ReferencePCGControl &control [[buffer(8)]], constant uint4 &counts [[buffer(9)]],
    uint lane [[thread_position_in_grid]]) {
    if (lane != 0 || control.state.x == 0) return;
    float rz = control.recurrence.x;
    float divisor = denominator[0];
    // Preserve the CPU guards, including finite non-positive denominators:
    // they stop without reporting a non-finite state or counting an iteration.
    if (!isfinite(divisor) || divisor <= 0x1p-23f || !isfinite(rz)) {
        control.state.x = 0;
        control.state.z = !isfinite(divisor) || !isfinite(rz) ? 1 : 0;
        return;
    }
    float alpha = rz / divisor;
    float squaredNorm = 0;
    for (uint i = 0; i < counts.x; ++i) {
        solution[i] = solution[i] + direction[i] * alpha;
        residual[i] = residual[i] + applied[i] * -alpha;
        squaredNorm += referenceDot(residual[i], residual[i]);
    }
    control.state.y += 1;
    float currentNorm = sqrt(max(0.0f, squaredNorm));
    control.norms.y = currentNorm;
    if (!isfinite(squaredNorm) || !isfinite(currentNorm)) {
        control.state.x = 0;
        control.state.z = 1;
        return;
    }
    if (currentNorm <= control.norms.z) { control.state.x = 0; return; }
    float nextRZ = 0;
    for (uint i = 0; i < counts.x; ++i) {
        preconditioned[i] = residual[i] * diagonal[i];
        nextRZ += referenceDot(residual[i], preconditioned[i]);
    }
    if (!isfinite(nextRZ)) {
        control.state.x = 0;
        control.state.z = 1;
        return;
    }
    control.recurrence.y = nextRZ / rz;
    control.recurrence.x = nextRZ;
}

kernel void referencePCGUpdateDirection(device const float2 *preconditioned [[buffer(4)]],
    device float2 *direction [[buffer(5)]], device const ReferencePCGControl &control [[buffer(8)]],
    constant uint4 &counts [[buffer(9)]], uint i [[thread_position_in_grid]]) {
    if (i < counts.x && control.state.x != 0)
        direction[i] = preconditioned[i] + direction[i] * control.recurrence.y;
}

kernel void referencePCGFinalize(device const float2 *solution [[buffer(2)]],
    device const float2 *residual [[buffer(3)]], device ReferencePCGControl &control [[buffer(8)]],
    constant uint4 &counts [[buffer(9)]], uint lane [[thread_position_in_grid]]) {
    if (lane != 0) return;
    float squaredNorm = 0;
    for (uint i = 0; i < counts.x; ++i) {
        squaredNorm += referenceDot(residual[i], residual[i]);
        if (!all(isfinite(solution[i]))) control.state.z = 1;
    }
    // CPU reports zero norms when the initial norm was rejected.
    control.norms.y = control.state.w != 0 ? 0 : sqrt(max(0.0f, squaredNorm));
    control.state.x = 0;
}
