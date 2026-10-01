#include <metal_stdlib>
using namespace metal;

struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalBubbleRange { uint id; uint centerIndex; uint boundaryStart; uint boundaryCount; float restArea; uint distanceConstraintStart; uint distanceConstraintCount; float padding; };
struct MetalSpringConstraint { uint firstIndex; uint secondIndex; float restLength; uint kind; float2 padding; };
struct MetalAreaConstraint { uint boundaryStart; uint boundaryCount; float restArea; float compliance; };

kernel void predictParticles(
    device MetalParticle *particles [[buffer(0)]], constant uint &particleCount [[buffer(1)]],
    constant float2 &gravity [[buffer(2)]], constant float &timeStep [[buffer(3)]],
    constant float &drag [[buffer(4)]], uint index [[thread_position_in_grid]]
) {
    if (index >= particleCount) { return; }
    MetalParticle particle = particles[index];
    const float2 position = particle.position;
    const float2 velocity = (position - particle.previousPosition) * exp(-max(0.0f, drag) * timeStep);
    particle.previousPosition = position;
    particle.position = position + velocity + gravity * timeStep * timeStep;
    particles[index] = particle;
}

kernel void solveBubbleShape(
    device MetalParticle *particles [[buffer(0)]], device const MetalBubbleRange *bubbleRanges [[buffer(1)]],
    device const MetalSpringConstraint *springConstraints [[buffer(2)]], device const MetalAreaConstraint *areaConstraints [[buffer(3)]],
    constant uint &bubbleCount [[buffer(4)]], constant float &timeStep [[buffer(5)]],
    constant float &quadraticStiffness [[buffer(6)]], constant float &quarticStiffness [[buffer(7)]],
    uint bubbleIndex [[thread_position_in_grid]]
) {
    if (bubbleIndex >= bubbleCount) { return; }
    const MetalBubbleRange range = bubbleRanges[bubbleIndex];
    for (uint offset = 0; offset < range.distanceConstraintCount; ++offset) {
        const MetalSpringConstraint constraint = springConstraints[range.distanceConstraintStart + offset];
        MetalParticle first = particles[constraint.firstIndex];
        MetalParticle second = particles[constraint.secondIndex];
        const float2 separation = second.position - first.position;
        const float distance = length(separation);
        if (distance <= 0.0000001f) { continue; }
        const float weight = first.inverseMass + second.inverseMass;
        if (weight <= 0.0f) { continue; }
        const float extension = distance - constraint.restLength;
        const float materialScale = constraint.padding.x;
        const float force = materialScale * (quadraticStiffness * extension + quarticStiffness * extension * extension * extension);
        const float tangent = materialScale * (quadraticStiffness + 3.0f * quarticStiffness * extension * extension);
        const float timeSquared = timeStep * timeStep;
        const float correction = force * timeSquared * weight / (1.0f + tangent * timeSquared * weight);
        if (!isfinite(correction)) { continue; }
        const float2 gradient = separation / distance;
        first.position += gradient * (first.inverseMass * correction / weight);
        second.position -= gradient * (second.inverseMass * correction / weight);
        particles[constraint.firstIndex] = first;
        particles[constraint.secondIndex] = second;
    }
    (void)areaConstraints;
}

kernel void solveWorldBounds(
    device MetalParticle *particles [[buffer(0)]], constant uint &particleCount [[buffer(1)]],
    constant float2 &minimum [[buffer(2)]], constant float2 &maximum [[buffer(3)]], uint index [[thread_position_in_grid]]
) {
    if (index >= particleCount) { return; }
    MetalParticle particle = particles[index];
    const float2 clamped = clamp(particle.position, minimum, maximum);
    particle.position = clamped;
    particle.previousPosition = clamped;
    particles[index] = particle;
}

kernel void recenterBubbleCenters(
    device MetalParticle *particles [[buffer(0)]],
    device const MetalBubbleRange *bubbleRanges [[buffer(1)]],
    constant uint &bubbleCount [[buffer(2)]],
    uint bubbleIndex [[thread_position_in_grid]]
) {
    if (bubbleIndex >= bubbleCount) { return; }
    const MetalBubbleRange range = bubbleRanges[bubbleIndex];
    if (range.boundaryCount == 0) { return; }
    float2 centroid = float2(0.0f), previousCentroid = float2(0.0f);
    for (uint offset = 0; offset < range.boundaryCount; ++offset) {
        const MetalParticle boundary = particles[range.boundaryStart + offset];
        centroid += boundary.position; previousCentroid += boundary.previousPosition;
    }
    MetalParticle center = particles[range.centerIndex];
    center.position = centroid / float(range.boundaryCount);
    center.previousPosition = previousCentroid / float(range.boundaryCount);
    particles[range.centerIndex] = center;
}
