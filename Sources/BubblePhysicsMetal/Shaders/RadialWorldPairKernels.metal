#include <metal_stdlib>
using namespace metal;

struct Body { float4 pose; float4 motion; float4 target; float4 padding; };
struct Sensor { float4 state; float4 pressureAndPadding; };
struct Descriptor { uint4 range; float4 radial; float4 response; float4 timing; float4 contact; };
struct PairRecord { uint4 bubblesAndRange; };
struct PairContact {
    uint4 first;
    uint4 second;
    float4 barycentricPenetration;
    float4 pointNormal;
};

float radialWorldCross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

bool segmentIntersection(
    float2 a, float2 b, float2 c, float2 d,
    thread float &t, thread float &u, thread float2 &point
) {
    const float2 r = b - a, s = d - c;
    const float denominator = radialWorldCross2(r, s);
    if (abs(denominator) <= 0.0000001f) return false;
    t = radialWorldCross2(c - a, s) / denominator;
    u = radialWorldCross2(c - a, r) / denominator;
    if (t < 0 || t > 1 || u < 0 || u > 1) return false;
    point = a + r * t;
    return true;
}

bool pointInside(float2 point, device const float2 *points, uint start, uint count) {
    bool inside = false;
    uint previous = count - 1;
    for (uint current = 0; current < count; ++current) {
        const float2 a = points[start + current], b = points[start + previous];
        if ((a.y > point.y) != (b.y > point.y)) {
            const float x = (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x;
            if (point.x < x) inside = !inside;
        }
        previous = current;
    }
    return inside;
}

void writePairContact(
    device PairContact *contacts, device atomic_uint *counts,
    PairRecord pair, uint pairIndex,
    uint firstStart, uint firstEnd, float firstT,
    uint secondStart, uint secondEnd, float secondT,
    float2 point, float2 normal, float penetration,
    device atomic_uint *metrics
) {
    const uint local = atomic_fetch_add_explicit(&counts[pairIndex], 1, memory_order_relaxed);
    const uint capacity = pair.bubblesAndRange.w;
    if (local >= capacity) {
        atomic_store_explicit(&metrics[2], 1, memory_order_relaxed);
        return;
    }
    PairContact value;
    value.first = uint4(pair.bubblesAndRange.x, pair.bubblesAndRange.y, firstStart, firstEnd);
    value.second = uint4(secondStart, secondEnd, 0, 0);
    value.barycentricPenetration = float4(firstT, secondT, penetration, 0);
    value.pointNormal = float4(point, normalize(normal));
    contacts[pair.bubblesAndRange.z + local] = value;
    atomic_fetch_add_explicit(&metrics[1], 1, memory_order_relaxed);
}

kernel void radialWorldGeneratePairContacts(
    device const Body *bodies [[buffer(0)]],
    device const Descriptor *descriptors [[buffer(1)]],
    device const float2 *points [[buffer(2)]],
    device const PairRecord *pairs [[buffer(3)]],
    device PairContact *contacts [[buffer(4)]],
    device atomic_uint *counts [[buffer(5)]],
    device atomic_uint *metrics [[buffer(6)]],
    constant uint &pairCount [[buffer(7)]],
    uint pairIndex [[thread_position_in_grid]]
) {
    if (pairIndex >= pairCount) return;
    const PairRecord pair = pairs[pairIndex];
    const uint firstBubble = pair.bubblesAndRange.x, secondBubble = pair.bubblesAndRange.y;
    if (bodies[firstBubble].target.x <= 0.0f || bodies[secondBubble].target.x <= 0.0f) return;
    const Descriptor first = descriptors[firstBubble], second = descriptors[secondBubble];
    float2 firstMin = float2(INFINITY), firstMax = float2(-INFINITY);
    float2 secondMin = float2(INFINITY), secondMax = float2(-INFINITY);
    for (uint i = 0; i < first.range.y; ++i) {
        firstMin = min(firstMin, points[first.range.x + i]); firstMax = max(firstMax, points[first.range.x + i]);
    }
    for (uint i = 0; i < second.range.y; ++i) {
        secondMin = min(secondMin, points[second.range.x + i]); secondMax = max(secondMax, points[second.range.x + i]);
    }
    if (firstMax.x < secondMin.x || secondMax.x < firstMin.x
        || firstMax.y < secondMin.y || secondMax.y < firstMin.y) return;
    atomic_fetch_add_explicit(&metrics[0], 1, memory_order_relaxed);

    for (uint i = 0; i < first.range.y; ++i) {
        const uint firstStart = first.range.x + i;
        const uint firstEnd = first.range.x + ((i + 1) % first.range.y);
        for (uint j = 0; j < second.range.y; ++j) {
            const uint secondStart = second.range.x + j;
            const uint secondEnd = second.range.x + ((j + 1) % second.range.y);
            float t, u; float2 point;
            if (!segmentIntersection(points[firstStart], points[firstEnd], points[secondStart], points[secondEnd], t, u, point)) continue;
            float2 edge = points[secondEnd] - points[secondStart];
            float2 normal = float2(edge.y, -edge.x);
            if (dot(normal, bodies[firstBubble].pose.xy - bodies[secondBubble].pose.xy) < 0) normal *= -1;
            writePairContact(contacts, counts, pair, pairIndex,
                firstStart, firstEnd, t, secondStart, secondEnd, u,
                point, normal, 0.0001f, metrics);
        }
    }

    for (uint side = 0; side < 2; ++side) {
        const Descriptor inner = side == 0 ? first : second;
        const Descriptor outer = side == 0 ? second : first;
        for (uint i = 0; i < inner.range.y; ++i) {
            const uint innerStart = inner.range.x + i;
            if (!pointInside(points[innerStart], points, outer.range.x, outer.range.y)) continue;
            float bestDistance = INFINITY, bestT = 0; uint bestStart = outer.range.x;
            float2 bestPoint = points[bestStart];
            for (uint j = 0; j < outer.range.y; ++j) {
                const uint start = outer.range.x + j, end = outer.range.x + ((j + 1) % outer.range.y);
                const float2 edge = points[end] - points[start];
                const float denominator = dot(edge, edge);
                const float t = denominator > 0.0000001f ? clamp(dot(points[innerStart] - points[start], edge) / denominator, 0.0f, 1.0f) : 0.0f;
                const float2 nearest = points[start] + edge * t;
                const float distance = length(nearest - points[innerStart]);
                if (distance < bestDistance) { bestDistance = distance; bestT = t; bestStart = start; bestPoint = nearest; }
            }
            if (bestDistance <= 0.000001f) continue;
            const uint innerEnd = inner.range.x + ((i + 1) % inner.range.y);
            const uint outerEnd = outer.range.x + (((bestStart - outer.range.x) + 1) % outer.range.y);
            const float2 outward = bestPoint - points[innerStart];
            if (side == 0) writePairContact(contacts, counts, pair, pairIndex,
                innerStart, innerEnd, 0, bestStart, outerEnd, bestT,
                points[innerStart], outward, bestDistance, metrics);
            else writePairContact(contacts, counts, pair, pairIndex,
                bestStart, outerEnd, bestT, innerStart, innerEnd, 0,
                points[innerStart], -outward, bestDistance, metrics);
        }
    }
}

float2 surfaceVelocity(Body body, device const Sensor *sensors, uint index, float2 point) {
    const float2 arm = point - body.pose.xy;
    const float angle = body.motion.x + sensors[index].state.x;
    return body.pose.zw + float2(-body.motion.y * arm.y, body.motion.y * arm.x)
        + float2(cos(angle), sin(angle)) * sensors[index].state.z;
}

kernel void radialWorldReducePairContacts(
    device const Body *bodies [[buffer(0)]],
    device const Descriptor *descriptors [[buffer(1)]],
    device const Sensor *sensors [[buffer(2)]],
    device const float2 *points [[buffer(3)]],
    device const PairRecord *pairs [[buffer(4)]],
    device const PairContact *contacts [[buffer(5)]],
    device const atomic_uint *counts [[buffer(6)]],
    device float4 *loads [[buffer(7)]],
    device float *compression [[buffer(8)]],
    device float *pressure [[buffer(9)]],
    constant uint &pairCount [[buffer(10)]],
    uint threadIndex [[thread_position_in_grid]]
) {
    if (threadIndex != 0) return;
    for (uint pairIndex = 0; pairIndex < pairCount; ++pairIndex) {
        const PairRecord pair = pairs[pairIndex];
        const uint count = min(atomic_load_explicit(&counts[pairIndex], memory_order_relaxed), pair.bubblesAndRange.w);
        for (uint local = 0; local < count; ++local) {
            const PairContact contact = contacts[pair.bubblesAndRange.z + local];
            const uint firstBubble = contact.first.x, secondBubble = contact.first.y;
            const uint fs = contact.first.z, fe = contact.first.w, ss = contact.second.x, se = contact.second.y;
            const float ft = contact.barycentricPenetration.x, st = contact.barycentricPenetration.y;
            const float penetration = contact.barycentricPenetration.z;
            const float2 point = contact.pointNormal.xy, normal = contact.pointNormal.zw;
            const float2 firstVelocity = mix(
                surfaceVelocity(bodies[firstBubble], sensors, fs, points[fs]),
                surfaceVelocity(bodies[firstBubble], sensors, fe, points[fe]), ft);
            const float2 secondVelocity = mix(
                surfaceVelocity(bodies[secondBubble], sensors, ss, points[ss]),
                surfaceVelocity(bodies[secondBubble], sensors, se, points[se]), st);
            const float closing = max(0.0f, -dot(firstVelocity - secondVelocity, normal));
            const float4 a = descriptors[firstBubble].contact, b = descriptors[secondBubble].contact;
            const float magnitude = max(0.0f,
                0.5f * (a.x + b.x) * penetration
                + 0.5f * (a.y + b.y) * penetration * penetration * penetration
                + closing * 0.5f * (a.z + b.z));
            const float2 force = normal * magnitude;
            const float bodyLoadWeight = min(
                1.0f, 16.0f / max(2.0f, float(descriptors[firstBubble].range.y + descriptors[secondBubble].range.y))
            );
            loads[firstBubble].xy += force * bodyLoadWeight; loads[secondBubble].xy -= force * bodyLoadWeight;
            loads[firstBubble].z += radialWorldCross2(point - bodies[firstBubble].pose.xy, force) * bodyLoadWeight;
            loads[secondBubble].z += radialWorldCross2(point - bodies[secondBubble].pose.xy, -force) * bodyLoadWeight;
            compression[fs] += penetration * (1 - ft); compression[fe] += penetration * ft;
            compression[ss] += penetration * (1 - st); compression[se] += penetration * st;
            pressure[fs] += magnitude * (1 - ft); pressure[fe] += magnitude * ft;
            pressure[ss] += magnitude * (1 - st); pressure[se] += magnitude * st;
        }
    }
}
