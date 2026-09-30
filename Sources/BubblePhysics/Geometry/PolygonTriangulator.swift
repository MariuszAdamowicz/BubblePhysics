enum PolygonTriangulationError: Error {
    case impossible
}

enum PolygonTriangulator {
    static func triangulate(counterClockwise vertices: [Vector2]) throws -> [Triangle] {
        var remaining = Array(vertices.indices)
        var triangles: [Triangle] = []

        while remaining.count > 3 {
            var foundEar = false
            for offset in remaining.indices {
                let previous = remaining[(offset + remaining.count - 1) % remaining.count]
                let current = remaining[offset]
                let next = remaining[(offset + 1) % remaining.count]
                let triangle = Triangle(a: vertices[previous], b: vertices[current], c: vertices[next])
                guard orientation(triangle.a, triangle.b, triangle.c) > 0.00001 else { continue }
                let containsOtherVertex = remaining.contains { candidate in
                    candidate != previous && candidate != current && candidate != next &&
                    pointIsInsideOrOnTriangle(vertices[candidate], triangle)
                }
                guard !containsOtherVertex else { continue }
                triangles.append(triangle)
                remaining.remove(at: offset)
                foundEar = true
                break
            }
            guard foundEar else { throw PolygonTriangulationError.impossible }
        }

        triangles.append(Triangle(a: vertices[remaining[0]], b: vertices[remaining[1]], c: vertices[remaining[2]]))
        return triangles
    }
}
