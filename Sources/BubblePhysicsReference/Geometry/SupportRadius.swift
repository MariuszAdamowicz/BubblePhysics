import Foundation

public extension ReferenceBubble {
    func supportRadius(along direction: ReferenceVector2) -> Float {
        let sampleDirection = direction.normalized(or: ReferenceVector2(x: 1, y: 0))
        var totalIndentation: Float = 0

        for deformation in directionalDeformations {
            let cosine = min(1, max(-1, sampleDirection.dot(deformation.direction)))
            let angle = acosf(cosine)
            guard angle < deformation.angularWidth else { continue }
            let normalizedInfluence = 1 - angle / deformation.angularWidth
            let smoothInfluence = normalizedInfluence * normalizedInfluence * (3 - 2 * normalizedInfluence)
            totalIndentation += deformation.depth * smoothInfluence
        }

        return max(0, targetRadius - totalIndentation)
    }
}
