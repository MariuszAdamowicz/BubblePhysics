import Foundation

public struct SpringMaterial: Equatable, Sendable {
    public let quadraticStiffness: Float
    public let quarticStiffness: Float
    public let drag: Float

    public init(quadraticStiffness: Float, quarticStiffness: Float, drag: Float) {
        precondition(quadraticStiffness >= 0 && quarticStiffness >= 0 && drag >= 0)
        self.quadraticStiffness = quadraticStiffness
        self.quarticStiffness = quarticStiffness
        self.drag = drag
    }

    public func springForce(extension value: Float) -> Float {
        quadraticStiffness * value + quarticStiffness * value * value * value
    }

    public func implicitLengthCorrection(extension value: Float, inverseMassSum: Float, deltaTime: Float) -> Float {
        guard inverseMassSum > 0, deltaTime > 0 else { return 0 }
        let tangent = quadraticStiffness + 3 * quarticStiffness * value * value
        let timeSquared = deltaTime * deltaTime
        return springForce(extension: value) * timeSquared * inverseMassSum /
            (1 + tangent * timeSquared * inverseMassSum)
    }

    public func velocityScale(deltaTime: Float) -> Float {
        exp(-drag * max(0, deltaTime))
    }

    public static let `default` = SpringMaterial(
        quadraticStiffness: 5_000,
        quarticStiffness: 50,
        drag: 3.08
    )
}

enum SpringKind: UInt32, CaseIterable, Sendable {
    case radial
    case perimeter
    case bending
}

struct SpringConstraint: Sendable {
    let first: Int
    let second: Int
    var restLength: Float
    let kind: SpringKind

    mutating func scaleRestLength(by scale: Float) {
        restLength *= scale
    }

    func project(particles: inout ParticleStore, timeStep: Float, material: SpringMaterial) {
        let firstParticle = particles[first]
        let secondParticle = particles[second]
        let separation = secondParticle.position - firstParticle.position
        let distance = length(separation)
        guard distance > 1e-7 else { return }
        let inverseMassSum = firstParticle.inverseMass + secondParticle.inverseMass
        guard inverseMassSum > 0 else { return }
        let correction = material.implicitLengthCorrection(
            extension: distance - restLength,
            inverseMassSum: inverseMassSum,
            deltaTime: timeStep
        )
        guard correction.isFinite else { return }
        let direction = separation * (1 / distance)
        particles[first].position = firstParticle.position + direction * (correction * firstParticle.inverseMass / inverseMassSum)
        particles[second].position = secondParticle.position - direction * (correction * secondParticle.inverseMass / inverseMassSum)
    }
}
