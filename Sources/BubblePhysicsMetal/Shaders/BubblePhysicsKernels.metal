#include <metal_stdlib>
using namespace metal;

kernel void predictParticles(
    device float2 *positions [[buffer(0)]],
    uint index [[thread_position_in_grid]]
) {
    positions[index] = positions[index];
}
