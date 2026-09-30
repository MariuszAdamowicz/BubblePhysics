#include <metal_stdlib>
using namespace metal;

struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalInteractionPolygon { uint vertexStart; uint vertexCount; float2 position; float2 linearVelocity; float angularVelocity; float padding; };
struct MetalGrab { uint particleIndex; uint padding; float2 target; float maximumCorrection; float3 trailingPadding; };

kernel void generatePolygonContacts(
    device MetalParticle *particles [[buffer(0)]], device const float2 *vertices [[buffer(1)]],
    device const MetalInteractionPolygon *polygons [[buffer(2)]], constant uint &particleCount [[buffer(3)]],
    constant uint &polygonCount [[buffer(4)]], constant float &timeStep [[buffer(5)]], uint index [[thread_position_in_grid]]
) {
    if (index >= particleCount || particles[index].bubbleIndex == UINT_MAX) { return; }
    MetalParticle particle = particles[index];
    for (uint polygonIndex = 0; polygonIndex < polygonCount; ++polygonIndex) {
        const MetalInteractionPolygon polygon = polygons[polygonIndex]; bool inside = false;
        float nearestDistance = INFINITY; float2 nearestProjection = particle.position;
        for (uint offset = 0; offset < polygon.vertexCount; ++offset) {
            const float2 start = vertices[polygon.vertexStart + offset]; const float2 end = vertices[polygon.vertexStart + (offset + 1) % polygon.vertexCount];
            if ((start.y > particle.position.y) != (end.y > particle.position.y)) { const float x = (end.x - start.x) * (particle.position.y - start.y) / (end.y - start.y) + start.x; if (particle.position.x < x) { inside = !inside; } }
            const float2 edge = end - start; const float denominator = dot(edge, edge); if (denominator <= 0.0f) { continue; }
            const float t = clamp(dot(particle.position - start, edge) / denominator, 0.0f, 1.0f); const float2 projection = start + edge * t; const float distance = length(projection - particle.position);
            if (distance < nearestDistance) { nearestDistance = distance; nearestProjection = projection; }
        }
        if (inside) { particle.position = nearestProjection; const float2 offset = particle.position - polygon.position; const float2 surfaceVelocity = polygon.linearVelocity + float2(-polygon.angularVelocity * offset.y, polygon.angularVelocity * offset.x); particle.previousPosition = particle.position - surfaceVelocity * timeStep; }
    }
    particles[index] = particle;
}

kernel void applyGrabConstraint(device MetalParticle *particles [[buffer(0)]], device const MetalGrab *grabs [[buffer(1)]], constant uint &grabCount [[buffer(2)]], uint index [[thread_position_in_grid]]) {
    if (index >= grabCount) { return; } const MetalGrab grab = grabs[index]; MetalParticle particle = particles[grab.particleIndex]; const float2 delta = grab.target - particle.position; const float distance = length(delta); if (distance > 0.0f) { particle.position += delta / distance * min(distance, grab.maximumCorrection); particles[grab.particleIndex] = particle; }
}

kernel void applyKinematicSurfaceVelocity(device MetalParticle *particles [[buffer(0)]], constant uint &particleCount [[buffer(1)]], uint index [[thread_position_in_grid]]) { if (index < particleCount) { particles[index] = particles[index]; } }
