import Foundation

public struct ReferenceVisualScene {
    public static let size = ReferenceVector2(x: 375, y: 700)

    public var world: ReferenceWorld
    public let triangleOwnerID: Int
    public let triangleSegmentIDs: [ReferenceSegmentID]
    public let triangleLocalVertices: [ReferenceVector2]

    public init(
        world: ReferenceWorld,
        triangleOwnerID: Int,
        triangleSegmentIDs: [ReferenceSegmentID],
        triangleLocalVertices: [ReferenceVector2]
    ) {
        self.world = world
        self.triangleOwnerID = triangleOwnerID
        self.triangleSegmentIDs = triangleSegmentIDs
        self.triangleLocalVertices = triangleLocalVertices
    }
}

public enum ReferenceVisualSceneFactory {
    public static func make() throws -> ReferenceVisualScene {
        var configuration = ReferenceConfiguration.default
        configuration.timeStep = 1 / 60
        configuration.maxContourSegmentLength = 6
        var world = ReferenceWorld(configuration: configuration, broadPhase: SweepAndPruneBroadPhase())

        let radii: [Float] = [8, 12, 16, 22, 30, 42, 60, 75]
        for index in 0..<40 {
            let column = index % 5
            let row = index / 5
            let radius = radii[index % radii.count]
            let center = ReferenceVector2(
                x: 38 + Float(column) * 74 + Float(row % 2) * 9,
                y: 42 + Float(row) * 86
            )
            world.addBubble(try ReferenceBubble(
                id: .init(rawValue: index + 1),
                center: center,
                velocity: .zero,
                mass: max(1, radius * radius * 0.02),
                targetRadius: radius,
                stiffness: 1.4,
                rotation: Float(index) * 0.31
            ))
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
        let localVertices = [
            ReferenceVector2(x: -54, y: 38),
            ReferenceVector2(x: 54, y: 38),
            ReferenceVector2(x: 0, y: -62)
        ]
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
            triangleLocalVertices: localVertices
        )
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
