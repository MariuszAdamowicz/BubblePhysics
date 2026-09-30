#include <metal_stdlib>
using namespace metal;

struct MetalParticle { float2 position; float2 previousPosition; float inverseMass; uint bubbleIndex; float2 padding; };
struct MetalBubbleRange { uint id; uint centerIndex; uint boundaryStart; uint boundaryCount; float restArea; uint distanceConstraintStart; uint distanceConstraintCount; float padding; };
struct MetalDistanceConstraint { uint firstIndex; uint secondIndex; float restLength; float compliance; };
struct MetalAreaConstraint { uint boundaryStart; uint boundaryCount; float restArea; float compliance; };

kernel void predictParticles(
    device MetalParticle *particles [[buffer(0)]], constant uint &particleCount [[buffer(1)]],
    constant float2 &gravity [[buffer(2)]], constant float &timeStep [[buffer(3)]],
    constant float &linearDamping [[buffer(4)]], uint index [[thread_position_in_grid]]
) {
    if (index >= particleCount) { return; }
    MetalParticle particle = particles[index];
    const float2 position = particle.position;
    const float2 velocity = (position - particle.previousPosition) * (1.0f - linearDamping);
    particle.previousPosition = position;
    particle.position = position + velocity + gravity * timeStep * timeStep;
    particles[index] = particle;
}

kernel void solveBubbleShape(
    device MetalParticle *particles [[buffer(0)]], device const MetalBubbleRange *bubbleRanges [[buffer(1)]],
    device const MetalDistanceConstraint *distanceConstraints [[buffer(2)]], device const MetalAreaConstraint *areaConstraints [[buffer(3)]],
    constant uint &bubbleCount [[buffer(4)]], constant float &timeStep [[buffer(5)]], uint bubbleIndex [[thread_position_in_grid]]
) {
    if (bubbleIndex >= bubbleCount) { return; }
    const MetalBubbleRange range = bubbleRanges[bubbleIndex];
    for (uint offset = 0; offset < range.distanceConstraintCount; ++offset) {
        const MetalDistanceConstraint constraint = distanceConstraints[range.distanceConstraintStart + offset];
        MetalParticle first = particles[constraint.firstIndex];
        MetalParticle second = particles[constraint.secondIndex];
        const float2 separation = second.position - first.position;
        const float distance = length(separation);
        if (distance <= 0.00001f) { continue; }
        const float alpha = constraint.compliance / (timeStep * timeStep);
        const float weight = first.inverseMass + second.inverseMass;
        if (weight + alpha <= 0.0f) { continue; }
        const float deltaLambda = -(distance - constraint.restLength) / (weight + alpha);
        const float2 gradient = separation / distance;
        first.position -= gradient * (first.inverseMass * deltaLambda);
        second.position += gradient * (second.inverseMass * deltaLambda);
        particles[constraint.firstIndex] = first;
        particles[constraint.secondIndex] = second;
    }

    const MetalAreaConstraint areaConstraint = areaConstraints[bubbleIndex];
    if (areaConstraint.boundaryCount < 3) { return; }
    float area = 0.0f;
    float weight = 0.0f;
    for (uint offset = 0; offset < areaConstraint.boundaryCount; ++offset) {
        const uint previousOffset = (offset + areaConstraint.boundaryCount - 1) % areaConstraint.boundaryCount;
        const uint nextOffset = (offset + 1) % areaConstraint.boundaryCount;
        const MetalParticle previous = particles[areaConstraint.boundaryStart + previousOffset];
        const MetalParticle current = particles[areaConstraint.boundaryStart + offset];
        const MetalParticle next = particles[areaConstraint.boundaryStart + nextOffset];
        area += current.position.x * next.position.y - current.position.y * next.position.x;
        const float2 gradient = float2((next.position.y - previous.position.y) * 0.5f, (previous.position.x - next.position.x) * 0.5f);
        weight += current.inverseMass * dot(gradient, gradient);
    }
    area *= 0.5f;
    const float alpha = areaConstraint.compliance / (timeStep * timeStep);
    if (weight + alpha <= 0.0f) { return; }
    const float deltaLambda = -(area - areaConstraint.restArea) / (weight + alpha);
    for (uint offset = 0; offset < areaConstraint.boundaryCount; ++offset) {
        const uint previousOffset = (offset + areaConstraint.boundaryCount - 1) % areaConstraint.boundaryCount;
        const uint nextOffset = (offset + 1) % areaConstraint.boundaryCount;
        MetalParticle current = particles[areaConstraint.boundaryStart + offset];
        const float2 previous = particles[areaConstraint.boundaryStart + previousOffset].position;
        const float2 next = particles[areaConstraint.boundaryStart + nextOffset].position;
        const float2 gradient = float2((next.y - previous.y) * 0.5f, (previous.x - next.x) * 0.5f);
        current.position += gradient * (current.inverseMass * deltaLambda);
        particles[areaConstraint.boundaryStart + offset] = current;
    }
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
