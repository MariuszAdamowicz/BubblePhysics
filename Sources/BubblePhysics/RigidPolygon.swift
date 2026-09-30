import Foundation

public enum RigidPolygonMode: Equatable, Sendable {
    case `static`
    case kinematic
}

public enum RigidPolygonError: Error, Equatable, Sendable {
    case tooFewVertices
    case repeatedVertex
    case selfIntersecting
    case zeroArea
    case triangulationFailed
}

public struct RigidPolygon: Sendable {
    public let id: PolygonID
    public let mode: RigidPolygonMode
    public let localVertices: [Vector2]
    public let triangles: [Triangle]
    public let boundaryEdges: [Segment]
    public private(set) var position: Vector2 = .zero
    public private(set) var angleRadians: Float = 0
    public private(set) var linearVelocity: Vector2 = .zero
    public private(set) var angularVelocity: Float = 0

    public var signedArea: Float { signedDoubleArea(localVertices) / 2 }

    public var worldVertices: [Vector2] {
        localVertices.map(transformToWorld)
    }

    public static func make(id: PolygonID, vertices: [Vector2], mode: RigidPolygonMode = .static) throws -> RigidPolygon {
        guard vertices.count >= 3 else { throw RigidPolygonError.tooFewVertices }
        guard Set(vertices).count == vertices.count else { throw RigidPolygonError.repeatedVertex }
        guard !hasSelfIntersection(vertices) else { throw RigidPolygonError.selfIntersecting }

        let orderedVertices = signedDoubleArea(vertices) < 0 ? Array(vertices.reversed()) : vertices
        guard abs(signedDoubleArea(orderedVertices)) > 0.00001 else { throw RigidPolygonError.zeroArea }
        let triangles: [Triangle]
        do {
            triangles = try PolygonTriangulator.triangulate(counterClockwise: orderedVertices)
        } catch {
            throw RigidPolygonError.triangulationFailed
        }
        let edges = orderedVertices.indices.map { index in
            Segment(start: orderedVertices[index], end: orderedVertices[(index + 1) % orderedVertices.count])
        }
        return RigidPolygon(id: id, mode: mode, localVertices: orderedVertices, triangles: triangles, boundaryEdges: edges)
    }

    public mutating func setKinematicTransform(
        position: Vector2,
        angleRadians: Float,
        linearVelocity: Vector2,
        angularVelocity: Float
    ) {
        guard mode == .kinematic else { return }
        self.position = position
        self.angleRadians = angleRadians
        self.linearVelocity = linearVelocity
        self.angularVelocity = angularVelocity
    }

    public func surfaceVelocity(at worldPoint: Vector2) -> Vector2 {
        guard mode == .kinematic else { return .zero }
        let offset = worldPoint - position
        return linearVelocity + Vector2(x: -angularVelocity * offset.y, y: angularVelocity * offset.x)
    }

    private func transformToWorld(_ point: Vector2) -> Vector2 {
        let cosine = cos(angleRadians)
        let sine = sin(angleRadians)
        return Vector2(x: point.x * cosine - point.y * sine + position.x, y: point.x * sine + point.y * cosine + position.y)
    }

    private static func hasSelfIntersection(_ vertices: [Vector2]) -> Bool {
        for firstIndex in vertices.indices {
            let firstNext = (firstIndex + 1) % vertices.count
            let first = Segment(start: vertices[firstIndex], end: vertices[firstNext])
            for secondIndex in vertices.indices where secondIndex > firstIndex {
                let secondNext = (secondIndex + 1) % vertices.count
                if firstIndex == secondIndex || firstNext == secondIndex || secondNext == firstIndex { continue }
                let second = Segment(start: vertices[secondIndex], end: vertices[secondNext])
                if segmentsIntersect(first, second) { return true }
            }
        }
        return false
    }
}
