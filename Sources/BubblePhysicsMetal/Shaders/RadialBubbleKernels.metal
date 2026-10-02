#include <metal_stdlib>
using namespace metal;

struct MetalRadialBody {
    float4 pose;
    float4 motion;
    float4 target;
    float4 padding;
};

struct MetalRadialSensor {
    float4 state;
    float4 pressureAndPadding;
};

struct MetalRadialContact {
    uint4 indicesAndSourceLow;
    float4 pointAndNormal;
    float4 penetrationBarycentricVelocity;
    float4 padding;
};

struct MetalRadialMaterial {
    float4 radial;
    float4 response;
    float4 timing;
};

struct MetalRadialContactMaterial { float4 values; };

struct MetalRadialStepParameters {
    uint sensorCount;
    uint contactCount;
    float deltaTime;
    float padding;
};

kernel void radialReduceContacts(
    device const MetalRadialContact *contacts [[buffer(0)]],
    device const MetalRadialBody *body [[buffer(1)]],
    device float4 *loadHeader [[buffer(2)]],
    device float *compression [[buffer(3)]],
    device float *pressure [[buffer(4)]],
    constant MetalRadialContactMaterial &material [[buffer(5)]],
    constant MetalRadialStepParameters &parameters [[buffer(6)]],
    device const uint *contactCount [[buffer(7)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) { return; }
    for (uint sensor = 0; sensor < parameters.sensorCount; ++sensor) {
        compression[sensor] = 0.0f;
        pressure[sensor] = 0.0f;
    }
    float2 totalForce = float2(0.0f);
    float totalTorque = 0.0f;
    const float bodyLoadWeight = min(1.0f, 8.0f / max(1.0f, float(parameters.sensorCount)));
    const uint actualContactCount = contactCount[0];
    for (uint contactIndex = 0; contactIndex < actualContactCount; ++contactIndex) {
        const MetalRadialContact contact = contacts[contactIndex];
        const uint start = contact.indicesAndSourceLow.x;
        const uint end = contact.indicesAndSourceLow.y;
        if (start >= parameters.sensorCount || end >= parameters.sensorCount) { continue; }
        const float penetration = max(0.0f, contact.penetrationBarycentricVelocity.x);
        const float barycentric = clamp(contact.penetrationBarycentricVelocity.y, 0.0f, 1.0f);
        const float2 suppliedNormal = contact.pointAndNormal.zw;
        const float normalLength = length(suppliedNormal);
        if (normalLength <= 0.000001f) { continue; }
        const float2 normal = suppliedNormal / normalLength;
        const float2 relativeVelocity = contact.penetrationBarycentricVelocity.zw;
        const float closingSpeed = max(0.0f, -dot(relativeVelocity, normal));
        const float magnitude = max(
            0.0f,
            material.values.x * penetration
                + material.values.y * penetration * penetration * penetration
                + closingSpeed * material.values.z * body->motion.z
        );
        const float startWeight = 1.0f - barycentric;
        compression[start] += penetration * startWeight;
        compression[end] += penetration * barycentric;
        pressure[start] += magnitude * startWeight;
        pressure[end] += magnitude * barycentric;
        const float2 force = normal * magnitude;
        const float2 arm = contact.pointAndNormal.xy - body->pose.xy;
        totalForce += force * bodyLoadWeight;
        totalTorque += (arm.x * force.y - arm.y * force.x) * bodyLoadWeight;
    }
    loadHeader[0] = float4(totalForce, totalTorque, 0.0f);
}

kernel void radialPredictBody(
    device MetalRadialBody *body [[buffer(0)]],
    device const float4 *loadHeader [[buffer(1)]],
    constant MetalRadialMaterial &material [[buffer(2)]],
    constant MetalRadialStepParameters &parameters [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    if (index != 0) { return; }
    const float dt = parameters.deltaTime;
    float2 velocity = body->pose.zw + loadHeader[0].xy * (dt / body->motion.z);
    float angularVelocity = body->motion.y + loadHeader[0].z * dt / body->motion.w;
    velocity *= exp(-material.response.z * dt);
    angularVelocity *= exp(-material.response.w * dt);
    body->pose.xy += velocity * dt;
    body->pose.zw = velocity;
    body->motion.x += angularVelocity * dt;
    body->motion.y = angularVelocity;
    body->target.y = min(1.0f, body->target.y + dt / material.timing.x);
}

kernel void radialIntegrateSurface(
    device const MetalRadialSensor *source [[buffer(0)]],
    device MetalRadialSensor *destination [[buffer(1)]],
    device const MetalRadialBody *body [[buffer(2)]],
    device const float *compression [[buffer(3)]],
    device const float *pressure [[buffer(4)]],
    constant MetalRadialMaterial &material [[buffer(5)]],
    constant MetalRadialStepParameters &parameters [[buffer(6)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= parameters.sensorCount) { return; }
    const uint previousIndex = (index + parameters.sensorCount - 1) % parameters.sensorCount;
    const uint nextIndex = (index + 1) % parameters.sensorCount;
    const MetalRadialSensor current = source[index];
    const float compressedLength = max(0.0f, current.state.y - compression[index] * material.response.y);
    const float progress = body->target.y;
    const float smoothProgress = progress * progress * (3.0f - 2.0f * progress);
    const float targetLength = body->target.x * smoothProgress;
    const float extensionValue = targetLength - compressedLength;
    const float radialForce = material.radial.x * extensionValue
        + material.radial.y * extensionValue * extensionValue * extensionValue;
    const float neighborForce = material.radial.w
        * (source[previousIndex].state.y + source[nextIndex].state.y - 2.0f * current.state.y);
    const float acceleration = radialForce + neighborForce
        - material.radial.z * current.state.z
        - pressure[index] * material.response.x;
    float velocity = clamp(
        current.state.z + acceleration * parameters.deltaTime,
        -material.timing.y,
        material.timing.y
    );
    float radialLength = max(0.0f, compressedLength + velocity * parameters.deltaTime);
    if (radialLength == 0.0f && velocity < 0.0f) { velocity = 0.0f; }
    if (!isfinite(radialLength) || !isfinite(velocity)) {
        radialLength = isfinite(compressedLength) ? compressedLength : 0.0f;
        velocity = 0.0f;
    }
    MetalRadialSensor result = current;
    result.state.y = radialLength;
    result.state.z = velocity;
    result.state.w = targetLength;
    result.pressureAndPadding.x = max(0.0f, pressure[index]);
    destination[index] = result;
}

kernel void radialBuildSurface(
    device const MetalRadialBody *body [[buffer(0)]],
    device const MetalRadialSensor *sensors [[buffer(1)]],
    device float2 *surfacePoints [[buffer(2)]],
    constant MetalRadialStepParameters &parameters [[buffer(3)]],
    uint index [[thread_position_in_grid]]
) {
    if (index >= parameters.sensorCount) { return; }
    const float angle = body->motion.x + sensors[index].state.x;
    surfacePoints[index] = body->pose.xy + float2(cos(angle), sin(angle)) * sensors[index].state.y;
}

struct RadialRenderOut { float4 position [[position]]; float2 local; };
struct RadialLabelOut { float4 position [[position]]; float2 uv; };
struct RadialLabelUniforms { float2 uvOrigin; float2 uvSize; float2 halfSize; };

float2 radialWorldToClip(float2 point, constant float4 &viewport) {
    return point * viewport.xy + viewport.zw;
}

vertex RadialRenderOut radialFillVertex(
    uint vertexID [[vertex_id]],
    device const MetalRadialBody *body [[buffer(0)]],
    device const float2 *surfacePoints [[buffer(1)]],
    constant float4 &viewport [[buffer(2)]],
    constant uint &sensorCount [[buffer(3)]]
) {
    const uint triangle = vertexID / 3;
    const uint corner = vertexID % 3;
    const float2 world = corner == 0 ? body->pose.xy
        : surfacePoints[(triangle + corner - 1) % sensorCount];
    const float2 clip = radialWorldToClip(world, viewport);
    RadialRenderOut out;
    out.position = float4(clip, 0, 1);
    out.local = clip * float2(0.5, -0.5) + 0.5;
    return out;
}

vertex RadialRenderOut radialOutlineVertex(
    uint vertexID [[vertex_id]],
    device const float2 *surfacePoints [[buffer(0)]],
    constant float4 &viewport [[buffer(1)]],
    constant uint &sensorCount [[buffer(2)]]
) {
    const float2 clip = radialWorldToClip(surfacePoints[vertexID % sensorCount], viewport);
    RadialRenderOut out;
    out.position = float4(clip, 0, 1);
    out.local = clip * float2(0.5, -0.5) + 0.5;
    return out;
}

vertex RadialRenderOut radialPolygonVertex(
    uint vertexID [[vertex_id]],
    device const float2 *vertices [[buffer(0)]],
    constant float4 &viewport [[buffer(1)]]
) {
    const float2 clip = radialWorldToClip(vertices[vertexID], viewport);
    RadialRenderOut out;
    out.position = float4(clip, 0, 1);
    out.local = clip * float2(0.5, -0.5) + 0.5;
    return out;
}

fragment float4 radialColorFragment(
    RadialRenderOut in [[stage_in]],
    constant float4 &color [[buffer(0)]]
) {
    const float glow = 0.82 + 0.18 * (1.0 - in.local.y);
    return float4(color.rgb * glow, color.a);
}

vertex RadialLabelOut radialLabelVertex(
    uint vertexID [[vertex_id]],
    device const MetalRadialBody *body [[buffer(0)]],
    constant float4 &viewport [[buffer(1)]],
    constant RadialLabelUniforms &label [[buffer(2)]]
) {
    constexpr float2 corners[6] = { {-1,-1}, {1,-1}, {-1,1}, {-1,1}, {1,-1}, {1,1} };
    const float2 axis = float2(cos(body->motion.x), sin(body->motion.x));
    const float2 perpendicular = float2(-axis.y, axis.x);
    const float2 corner = corners[vertexID];
    const float2 world = body->pose.xy
        + axis * corner.x * label.halfSize.x
        + perpendicular * corner.y * label.halfSize.y;
    RadialLabelOut out;
    out.position = float4(radialWorldToClip(world, viewport), 0, 1);
    out.uv = label.uvOrigin + (corner * 0.5 + 0.5) * label.uvSize;
    return out;
}

fragment float4 radialLabelFragment(
    RadialLabelOut in [[stage_in]],
    texture2d<float> atlas [[texture(0)]]
) {
    constexpr sampler textureSampler(filter::linear, address::clamp_to_edge);
    const float alpha = atlas.sample(textureSampler, in.uv).r;
    return float4(0.06, 0.08, 0.12, alpha);
}
