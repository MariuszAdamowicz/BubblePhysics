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
    uint sensorStart,
    uint sensorEnd,
    float barycentric,
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
    contact.indicesAndSourceLow = uint4(sensorStart, sensorEnd, sourceLow, sourceHigh);
    contact.pointAndNormal = float4(point, normal);
    contact.penetrationBarycentricVelocity = float4(penetration, barycentric, relativeVelocity);
    contact.padding = float4(0.0f);
    contacts[count++] = contact;
}

bool radialSegmentIntersection(
    float2 a, float2 b, float2 c, float2 d,
    thread float &firstParameter, thread float &secondParameter, thread float2 &point
) {
    const float2 r = b - a;
    const float2 s = d - c;
    const float denominator = r.x * s.y - r.y * s.x;
    if (abs(denominator) <= 0.0000001f) { return false; }
    const float2 offset = c - a;
    firstParameter = (offset.x * s.y - offset.y * s.x) / denominator;
    secondParameter = (offset.x * r.y - offset.y * r.x) / denominator;
    if (firstParameter < 0.0f || firstParameter > 1.0f || secondParameter < 0.0f || secondParameter > 1.0f) {
        return false;
    }
    point = a + r * firstParameter;
    return true;
}

float2 radialPolygonVelocity(MetalRadialPolygon polygon, float2 point) {
    if (polygon.rangeAndMode.z != 1) { return float2(0.0f); }
    const float2 position = polygon.positionAndVelocityX.xy;
    const float2 linearVelocity = float2(polygon.positionAndVelocityX.z, polygon.velocityYAngularPadding.x);
    const float angularVelocity = polygon.velocityYAngularPadding.y;
    const float2 arm = point - position;
    return linearVelocity + float2(-angularVelocity * arm.y, angularVelocity * arm.x);
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
        const uint next = (sensor + 1) % parameters.sensorCount;
        const float2 a = surfacePoints[sensor];
        const float2 b = surfacePoints[next];
        for (uint wall = 0; wall < 4; ++wall) {
            float depthA = 0.0f;
            float depthB = 0.0f;
            float2 normal = float2(0.0f);
            if (wall == 0) { depthA = parameters.bounds.x - a.x; depthB = parameters.bounds.x - b.x; normal = float2(1, 0); }
            if (wall == 1) { depthA = a.x - parameters.bounds.z; depthB = b.x - parameters.bounds.z; normal = float2(-1, 0); }
            if (wall == 2) { depthA = parameters.bounds.y - a.y; depthB = parameters.bounds.y - b.y; normal = float2(0, 1); }
            if (wall == 3) { depthA = a.y - parameters.bounds.w; depthB = b.y - parameters.bounds.w; normal = float2(0, -1); }
            if (depthA <= 0.0f && depthB <= 0.0f) { continue; }
            float t = 0.5f;
            if (depthA <= 0.0f || depthB <= 0.0f) {
                const float crossing = depthA / (depthA - depthB);
                t = depthA > 0.0f ? crossing * 0.5f : (crossing + 1.0f) * 0.5f;
            }
            const float penetration = mix(depthA, depthB, t);
            const float2 point = mix(a, b, t);
            const float2 velocity = mix(
                radialSurfaceVelocity(body, sensors, sensor, a),
                radialSurfaceVelocity(body, sensors, next, b), t
            );
            radialWriteContact(
                contacts, overflow, count, parameters, sensor, next, t, point,
                normal, penetration, velocity, sensor, wall
            );
        }
    }

    for (uint polygonIndex = 0; polygonIndex < parameters.polygonCount; ++polygonIndex) {
        const MetalRadialPolygon polygon = polygons[polygonIndex];
        const uint vertexStart = polygon.rangeAndMode.x;
        const uint vertexCount = polygon.rangeAndMode.y;
        if (vertexCount < 3) { continue; }
        float2 polygonCenter = float2(0.0f);
        for (uint vertexIndex = 0; vertexIndex < vertexCount; ++vertexIndex) {
            polygonCenter += polygonVertices[vertexStart + vertexIndex];
        }
        polygonCenter /= float(vertexCount);

        for (uint sensor = 0; sensor < parameters.sensorCount; ++sensor) {
            const uint next = (sensor + 1) % parameters.sensorCount;
            const float2 a = surfacePoints[sensor];
            const float2 b = surfacePoints[next];
            for (uint edge = 0; edge < vertexCount; ++edge) {
                const float2 c = polygonVertices[vertexStart + edge];
                const float2 d = polygonVertices[vertexStart + ((edge + 1) % vertexCount)];
                float t = 0.0f;
                float u = 0.0f;
                float2 point = float2(0.0f);
                if (!radialSegmentIntersection(a, b, c, d, t, u, point)) { continue; }
                const float2 direction = d - c;
                float2 normal = normalize(float2(direction.y, -direction.x));
                if (dot(normal, point - polygonCenter) < 0.0f) { normal *= -1.0f; }
                const float2 velocity = mix(
                    radialSurfaceVelocity(body, sensors, sensor, a),
                    radialSurfaceVelocity(body, sensors, next, b), t
                );
                radialWriteContact(
                    contacts, overflow, count, parameters, sensor, next, t, point,
                    normal, 0.0001f, velocity - radialPolygonVelocity(polygon, point),
                    sensor, 0x10000000u | polygonIndex
                );
            }

            if (radialContains(a, polygonVertices, vertexStart, vertexCount)) {
                float bestDistanceSquared = INFINITY;
                float2 bestPoint = a;
                for (uint edge = 0; edge < vertexCount; ++edge) {
                    const float2 c = polygonVertices[vertexStart + edge];
                    const float2 d = polygonVertices[vertexStart + ((edge + 1) % vertexCount)];
                    const float2 direction = d - c;
                    const float denominator = dot(direction, direction);
                    const float t = denominator > 0.0000001f ? clamp(dot(a - c, direction) / denominator, 0.0f, 1.0f) : 0.0f;
                    const float2 nearest = c + direction * t;
                    const float distanceSquared = dot(nearest - a, nearest - a);
                    if (distanceSquared < bestDistanceSquared) { bestDistanceSquared = distanceSquared; bestPoint = nearest; }
                }
                if (bestDistanceSquared > 0.000000000001f) {
                    radialWriteContact(
                        contacts, overflow, count, parameters, sensor, next, 0.0f, a,
                        normalize(bestPoint - a), sqrt(bestDistanceSquared),
                        radialSurfaceVelocity(body, sensors, sensor, a) - radialPolygonVelocity(polygon, a),
                        sensor, 0x10800000u | polygonIndex
                    );
                }
            }
        }

        for (uint vertexIndex = 0; vertexIndex < vertexCount; ++vertexIndex) {
            const float2 point = polygonVertices[vertexStart + vertexIndex];
            if (!radialContains(point, surfacePoints, 0, parameters.sensorCount)) { continue; }
            float bestDistanceSquared = INFINITY;
            float2 bestPoint = point;
            uint bestSensor = 0;
            float bestT = 0.0f;
            for (uint sensor = 0; sensor < parameters.sensorCount; ++sensor) {
                const float2 a = surfacePoints[sensor];
                const float2 b = surfacePoints[(sensor + 1) % parameters.sensorCount];
                const float2 direction = b - a;
                const float denominator = dot(direction, direction);
                const float t = denominator > 0.0000001f ? clamp(dot(point - a, direction) / denominator, 0.0f, 1.0f) : 0.0f;
                const float2 nearest = a + direction * t;
                const float distanceSquared = dot(nearest - point, nearest - point);
                if (distanceSquared < bestDistanceSquared) {
                    bestDistanceSquared = distanceSquared; bestPoint = nearest; bestSensor = sensor; bestT = t;
                }
            }
            if (bestDistanceSquared <= 0.000000000001f) { continue; }
            const uint next = (bestSensor + 1) % parameters.sensorCount;
            const float2 velocity = mix(
                radialSurfaceVelocity(body, sensors, bestSensor, surfacePoints[bestSensor]),
                radialSurfaceVelocity(body, sensors, next, surfacePoints[next]), bestT
            );
            radialWriteContact(
                contacts, overflow, count, parameters, bestSensor, next, bestT, bestPoint,
                normalize(bestPoint - point), sqrt(bestDistanceSquared),
                velocity - radialPolygonVelocity(polygon, bestPoint),
                bestSensor, 0x11000000u | polygonIndex
            );
        }
    }
    contactCount[0] = count;
}
