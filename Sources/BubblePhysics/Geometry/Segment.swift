public struct Segment: Equatable, Sendable {
    public let start: Vector2
    public let end: Vector2

    public init(start: Vector2, end: Vector2) {
        self.start = start
        self.end = end
    }
}

public struct Triangle: Equatable, Sendable {
    public let a: Vector2
    public let b: Vector2
    public let c: Vector2

    public init(a: Vector2, b: Vector2, c: Vector2) {
        self.a = a
        self.b = b
        self.c = c
    }
}

func cross(_ left: Vector2, _ right: Vector2) -> Float {
    left.x * right.y - left.y * right.x
}

func signedDoubleArea(_ vertices: [Vector2]) -> Float {
    guard vertices.count >= 3 else { return 0 }
    return vertices.indices.reduce(0) { sum, index in
        let next = vertices[(index + 1) % vertices.count]
        return sum + cross(vertices[index], next)
    }
}

func orientation(_ first: Vector2, _ second: Vector2, _ third: Vector2) -> Float {
    cross(second - first, third - first)
}

func pointIsInsideOrOnTriangle(_ point: Vector2, _ triangle: Triangle) -> Bool {
    let first = orientation(triangle.a, triangle.b, point)
    let second = orientation(triangle.b, triangle.c, point)
    let third = orientation(triangle.c, triangle.a, point)
    return first >= -0.00001 && second >= -0.00001 && third >= -0.00001
}

func segmentsIntersect(_ first: Segment, _ second: Segment) -> Bool {
    let a = orientation(first.start, first.end, second.start)
    let b = orientation(first.start, first.end, second.end)
    let c = orientation(second.start, second.end, first.start)
    let d = orientation(second.start, second.end, first.end)
    return (a > 0 && b < 0 || a < 0 && b > 0) && (c > 0 && d < 0 || c < 0 && d > 0)
}
