#include <metal_stdlib>
using namespace metal;

struct MetalRadialBody { float4 pose; float4 motion; float4 target; float4 padding; };
struct MetalRadialSensor { float4 state; float4 pressureAndPadding; };
struct MetalRadialWorldDescriptor {
    uint4 range;
    float4 radial;
    float4 response;
    float4 timing;
};

kernel void radialWorldFreeStep(
    device MetalRadialBody *bodies [[buffer(0)]],
    device const MetalRadialWorldDescriptor *descriptors [[buffer(1)]],
    device const MetalRadialSensor *source [[buffer(2)]],
    device MetalRadialSensor *destination [[buffer(3)]],
    device float2 *surfacePoints [[buffer(4)]],
    constant uint4 &parameters [[buffer(5)]],
    uint bubbleIndex [[thread_position_in_grid]]
) {
    if (bubbleIndex >= parameters.x) { return; }
    const float dt = as_type<float>(parameters.z);
    const MetalRadialWorldDescriptor descriptor = descriptors[bubbleIndex];
    MetalRadialBody body = bodies[bubbleIndex];

    body.pose.zw *= exp(-descriptor.response.z * dt);
    body.motion.y *= exp(-descriptor.response.w * dt);
    body.pose.xy += body.pose.zw * dt;
    body.motion.x += body.motion.y * dt;
    body.target.y = min(1.0f, body.target.y + dt / descriptor.timing.x);
    bodies[bubbleIndex] = body;

    const float progress = body.target.y;
    const float currentTarget = body.target.x * progress * progress * (3.0f - 2.0f * progress);
    const uint start = descriptor.range.x;
    const uint count = descriptor.range.y;
    for (uint local = 0; local < count; ++local) {
        const uint index = start + local;
        const uint previousIndex = start + ((local + count - 1) % count);
        const uint nextIndex = start + ((local + 1) % count);
        MetalRadialSensor sensor = source[index];
        const float extensionValue = currentTarget - sensor.state.y;
        const float radialForce = descriptor.radial.x * extensionValue
            + descriptor.radial.y * extensionValue * extensionValue * extensionValue;
        const float neighborForce = descriptor.radial.w
            * (source[previousIndex].state.y + source[nextIndex].state.y - 2.0f * sensor.state.y);
        const float acceleration = radialForce + neighborForce - descriptor.radial.z * sensor.state.z;
        float velocity = clamp(
            sensor.state.z + acceleration * dt,
            -descriptor.timing.y, descriptor.timing.y
        );
        float length = max(0.0f, sensor.state.y + velocity * dt);
        if (length == 0.0f && velocity < 0.0f) { velocity = 0.0f; }
        sensor.state.y = length;
        sensor.state.z = velocity;
        sensor.state.w = currentTarget;
        sensor.pressureAndPadding.x = 0.0f;
        destination[index] = sensor;

        const float angle = body.motion.x + sensor.state.x;
        surfacePoints[index] = body.pose.xy + float2(cos(angle), sin(angle)) * length;
    }
}
