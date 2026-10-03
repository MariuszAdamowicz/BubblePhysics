import Foundation

public struct ReferenceVisualScene {
    public static let size = ReferenceVector2(x: 375, y: 700)

    public var world: ReferenceWorld
    public let triangleOwnerID: Int
    public let triangleSegmentIDs: [ReferenceSegmentID]
    public let triangleLocalVertices: [ReferenceVector2]
    public let valuesByBubbleID: [ReferenceBubbleID: Int]

    public init(
        world: ReferenceWorld,
        triangleOwnerID: Int,
        triangleSegmentIDs: [ReferenceSegmentID],
        triangleLocalVertices: [ReferenceVector2],
        valuesByBubbleID: [ReferenceBubbleID: Int]
    ) {
        self.world = world
        self.triangleOwnerID = triangleOwnerID
        self.triangleSegmentIDs = triangleSegmentIDs
        self.triangleLocalVertices = triangleLocalVertices
        self.valuesByBubbleID = valuesByBubbleID
    }
}

public enum ReferenceVisualSceneFactory {
    public static func make() throws -> ReferenceVisualScene {
        var configuration = ReferenceConfiguration.default
        configuration.timeStep = 1 / 60
        configuration.maxContourSegmentLength = 6
        var world = ReferenceWorld(configuration: configuration, broadPhase: SweepAndPruneBroadPhase())

        let values = [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048]
        let radii: [Float] = [8, 11, 16, 22, 30, 39, 49, 58, 66, 72, 75]
        let radiusByValue = Dictionary(uniqueKeysWithValues: zip(values, radii))
        let requestedValues = (values + Array(repeating: 2, count: 29)).sorted {
            radiusByValue[$0]! > radiusByValue[$1]!
        }
        let localVertices = [
            ReferenceVector2(x: -54, y: 38), ReferenceVector2(x: 54, y: 38), ReferenceVector2(x: 0, y: -62)
        ]
        let initialTriangle = triangleVertices(localVertices: localVertices, at: 0)
        var placed: [(center: ReferenceVector2, radius: Float)] = []
        var valuesByBubbleID: [ReferenceBubbleID: Int] = [:]
        for (index, value) in requestedValues.enumerated() {
            let radius = radiusByValue[value]!
            guard let center = packedCenter(radius: radius, existing: placed, triangle: initialTriangle) else {
                throw ReferenceModelError.nonFiniteValue
            }
            let id = ReferenceBubbleID(rawValue: index + 1)
            world.addBubble(try ReferenceBubble(
                id: id,
                center: center,
                velocity: .zero,
                mass: max(1, radius * radius * 0.02),
                targetRadius: radius,
                stiffness: 24 / radius,
                rotation: Float(index) * 0.31
            ))
            placed.append((center, radius))
            valuesByBubbleID[id] = value
        }

        world.addSegment(.staticSegment(
            id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 0, y: 700),
            collisionMode: .oneSided(allowedSide: -1)
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 2), a: .init(x: 375, y: 0), b: .init(x: 375, y: 700),
            collisionMode: .oneSided(allowedSide: 1)
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 3), a: .init(x: 0, y: 0), b: .init(x: 375, y: 0),
            collisionMode: .oneSided(allowedSide: 1)
        ))
        world.addSegment(.staticSegment(
            id: .init(rawValue: 4), a: .init(x: 0, y: 700), b: .init(x: 375, y: 700),
            collisionMode: .oneSided(allowedSide: -1)
        ))

        let ownerID = 100
        let segmentIDs = [5, 6, 7].map { ReferenceSegmentID(rawValue: $0) }
        let vertices = triangleVertices(localVertices: localVertices, at: 0)
        for edgeIndex in 0..<3 {
            world.addSegment(.kinematicSegment(
                id: segmentIDs[edgeIndex],
                previousA: vertices[edgeIndex],
                previousB: vertices[(edgeIndex + 1) % 3],
                currentA: vertices[edgeIndex],
                currentB: vertices[(edgeIndex + 1) % 3],
                ownerID: ownerID,
                collisionMode: .twoSided
            ))
        }

        return ReferenceVisualScene(
            world: world,
            triangleOwnerID: ownerID,
            triangleSegmentIDs: segmentIDs,
            triangleLocalVertices: localVertices,
            valuesByBubbleID: valuesByBubbleID
        )
    }

    private static func packedCenter(
        radius: Float, existing: [(center: ReferenceVector2, radius: Float)], triangle: [ReferenceVector2]
    ) -> ReferenceVector2? {
        let margin = max(0, radius - 2)
        var best: (point: ReferenceVector2, score: Float)?
        var y = margin
        while y <= ReferenceVisualScene.size.y - margin {
            var x = margin
            while x <= ReferenceVisualScene.size.x - margin {
                let point = ReferenceVector2(x: x, y: y)
                let gaps = existing.map { (point - $0.center).length - radius - $0.radius }
                let clearOfBubbles = gaps.allSatisfy { $0 >= -2 }
                if clearOfBubbles && clearOfTriangle(point, radius: radius, vertices: triangle) {
                    let score = gaps.min() ?? 0
                    if best == nil || score > best!.score { best = (point, score) }
                }
                x += 4
            }
            y += 4
        }
        return best?.point
    }

    private static func clearOfTriangle(_ point: ReferenceVector2, radius: Float, vertices: [ReferenceVector2]) -> Bool {
        let crosses = vertices.indices.map { index in
            (vertices[(index + 1) % 3] - vertices[index]).cross(point - vertices[index])
        }
        if crosses.allSatisfy({ $0 >= 0 }) || crosses.allSatisfy({ $0 <= 0 }) { return false }
        let required = max(0, radius - 2)
        return vertices.indices.allSatisfy { index in
            closestPoint(to: point, on: .init(a: vertices[index], b: vertices[(index + 1) % 3]))
                .distanceSquared >= required * required
        }
    }

    static func triangleVertices(
        localVertices: [ReferenceVector2],
        at time: Double
    ) -> [ReferenceVector2] {
        let t = Float(time)
        let center = ReferenceVector2(
            x: 187.5 + sinf(t * 0.73) * 82,
            y: 350 + sinf(t * 0.47) * 118
        )
        let angle = t * 0.82
        let cosine = cosf(angle)
        let sine = sinf(angle)
        return localVertices.map { point in
            center + ReferenceVector2(
                x: point.x * cosine - point.y * sine,
                y: point.x * sine + point.y * cosine
            )
        }
    }
}
