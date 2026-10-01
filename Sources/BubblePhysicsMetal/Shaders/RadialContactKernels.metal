#include <metal_stdlib>
using namespace metal;

struct MetalRadialBody { float4 pose; float4 motion; float4 target; float4 padding; };
struct MetalRadialSensor { float4 state; float4 pressureAndPadding; };
struct MetalRadialContact {
    uint4 indicesAndSourceLow;
    float4 pointAndNormal;
    float4 penetrationBarycentricVelocity;
    float4 padding;
};
struct MetalRadialPolygon {
    uint4 rangeAndMode;
    float4 positionAndVelocityX;
    float4 velocityYAngularPadding;
};
struct MetalRadialEnvironmentParameters {
    float4 bounds;
    uint sensorCount;
    uint polygonCount;
    uint contactCapacity;
    uint padding;
};

float2 radialSurfaceVelocity(
    device const MetalRadialBody *body,
    device const MetalRadialSensor *sensors,
    uint sensorIndex,
    float2 point
) {
    const float2 arm = point - body->pose.xy;
    const float angle = body->motion.x + sensors[sensorIndex].state.x;
    const float2 radial = float2(cos(angle), sin(angle)) * sensors[sensorIndex].state.z;
    return body->pose.zw + float2(-body->motion.y * arm.y, body->motion.y * arm.x) + radial;
}

bool radialContains(float2 point, device const float2 *vertices, uint start, uint count) {
    bool inside = false;
    for (uint offset = 0; offset < count; ++offset) {
        const float2 a = vertices[start + offset];
        const float2 b = vertices[start + ((offset + 1) % count)];
        if ((a.y > point.y) != (b.y > point.y)) {
            const float crossingX = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
            if (point.x < crossingX) { inside = !inside; }
        }
    }
    return inside;
}

void radialWriteContact(
    device MetalRadialContact *contacts,
    device uint *overflow,
    thread uint &count,
    constant MetalRadialEnvironmentParameters &parameters,
    uint sensor,
    float2 point,
    float2 normal,
    float penetration,
    float2 relativeVelocity,
    uint sourceLow,
    uint sourceHigh
) {
    if (count >= parameters.contactCapacity) {
        overflow[0] = 1;
        return;
    }
    MetalRadialContact contact;
    contact.indicesAndSourceLow = uint4(sensor, (sensor + 1) % parameters.sensorCount, sourceLow, sourceHigh);
    contact.pointAndNormal = float4(point, normal);
    contact.penetrationBarycentricVelocity = float4(penetration, 0.0f, relativeVelocity);
    contact.padding = float4(0.0f);
    contacts[count++] = contact;
}

kernel void radialGenerateEnvironmentContacts(
    device const MetalRadialBody *body [[buffer(0)]],
    device const MetalRadialSensor *sensors [[buffer(1)]],
    device const float2 *surfacePoints [[buffer(2)]],
    device const float2 *polygonVertices [[buffer(3)]],
    device const MetalRadialPolygon *polygons [[buffer(4)]],
    device MetalRadialContact *contacts [[buffer(5)]],
    device uint *contactCount [[buffer(6)]],
    device uint *overflow [[buffer(7)]],
    constant MetalRadialEnvironmentParameters &parameters [[buffer(8)]],
    uint threadIndex [[thread_position_in_grid]]
) {
    if (threadIndex != 0) { return; }
    uint count = 0;
    overflow[0] = 0;
    for (uint sensor = 0; sensor < parameters.sensorCount; ++sensor) {
        const float2 point = surfacePoints[sensor];
        const float2 velocity = radialSurfaceVelocity(body, sensors, sensor, point);
        if (point.x < parameters.bounds.x) {
            radialWriteContact(contacts, overflow, count, parameters, sensor, point, float2(1, 0), parameters.bounds.x - point.x, velocity, sensor, 0);
        }
        if (point.x > parameters.bounds.z) {
            radialWriteContact(contacts, overflow, count, parameters, sensor, point, float2(-1, 0), point.x - parameters.bounds.z, velocity, sensor, 1);
        }
        if (point.y < parameters.bounds.y) {
            radialWriteContact(contacts, overflow, count, parameters, sensor, point, float2(0, 1), parameters.bounds.y - point.y, velocity, sensor, 2);
        }
        if (point.y > parameters.bounds.w) {
            radialWriteContact(contacts, overflow, count, parameters, sensor, point, float2(0, -1), point.y - parameters.bounds.w, velocity, sensor, 3);
        }

        for (uint polygonIndex = 0; polygonIndex < parameters.polygonCount; ++polygonIndex) {
            const MetalRadialPolygon polygon = polygons[polygonIndex];
            const uint start = polygon.rangeAndMode.x;
            const uint vertexCount = polygon.rangeAndMode.y;
            if (vertexCount < 3 || !radialContains(point, polygonVertices, start, vertexCount)) { continue; }
            float bestDistanceSquared = INFINITY;
            float2 bestPoint = point;
            float2 fallback = float2(1, 0);
            for (uint edge = 0; edge < vertexCount; ++edge) {
                const float2 a = polygonVertices[start + edge];
                const float2 b = polygonVertices[start + ((edge + 1) % vertexCount)];
                const float2 direction = b - a;
                const float lengthSquared = dot(direction, direction);
                const float t = lengthSquared > 0.0000001f ? clamp(dot(point - a, direction) / lengthSquared, 0.0f, 1.0f) : 0.0f;
                const float2 nearest = a + direction * t;
                const float distanceSquared = dot(nearest - point, nearest - point);
                if (distanceSquared < bestDistanceSquared) {
                    bestDistanceSquared = distanceSquared;
                    bestPoint = nearest;
                    fallback = float2(direction.y, -direction.x);
                }
            }
            float2 normalVector = bestPoint - point;
            if (length(normalVector) <= 0.000001f) { normalVector = fallback; }
            const float2 normal = normalize(normalVector);
            float2 polygonVelocity = float2(0.0f);
            if (polygon.rangeAndMode.z == 1) {
                const float2 position = polygon.positionAndVelocityX.xy;
                const float2 linearVelocity = float2(polygon.positionAndVelocityX.z, polygon.velocityYAngularPadding.x);
                const float angularVelocity = polygon.velocityYAngularPadding.y;
                const float2 arm = point - position;
                polygonVelocity = linearVelocity + float2(-angularVelocity * arm.y, angularVelocity * arm.x);
            }
            radialWriteContact(
                contacts, overflow, count, parameters, sensor, point, normal,
                sqrt(bestDistanceSquared), velocity - polygonVelocity,
                sensor, 0x10000000u | polygonIndex
            );
        }
    }
    contactCount[0] = count;
}
