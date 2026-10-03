public struct ReferenceVisualScene {
    public static let size = ReferenceVector2(x: 375, y: 700)
    public var world: ReferenceWorld
    public let polygonOwnerID: Int
    public let polygonSegmentIDs: [ReferenceSegmentID]
    public let polygonLocalVertices: [ReferenceVector2]
    public let valuesByBubbleID: [ReferenceBubbleID: Int]
    public var triangleOwnerID: Int { polygonOwnerID }
    public var triangleSegmentIDs: [ReferenceSegmentID] { polygonSegmentIDs }
    public var triangleLocalVertices: [ReferenceVector2] { polygonLocalVertices }
}

public enum ReferenceVisualSceneFactory {
    public static let initialPolygonCenter = ReferenceVector2(x: 187.5, y: 350)

    public static func make() throws -> ReferenceVisualScene {
        var configuration = ReferenceConfiguration.default
        configuration.timeStep = 1 / 60
        configuration.maxContourSegmentLength = 5
        configuration.contactStiffness = 300
        configuration.contactDamping = 26
        configuration.linearDamping = 0.8
        configuration.maximumEventGroups = 12
        var world = ReferenceWorld(configuration: configuration, broadPhase: SweepAndPruneBroadPhase())
        let specifications: [(Int, ReferenceVector2, Float)] = [
            (2, .init(x: 72, y: 125), 28), (8, .init(x: 182, y: 128), 42),
            (32, .init(x: 305, y: 130), 54), (128, .init(x: 82, y: 350), 62),
            (512, .init(x: 292, y: 365), 78), (2048, .init(x: 185, y: 590), 96),
        ]
        var values: [ReferenceBubbleID: Int] = [:]
        for (index, item) in specifications.enumerated() {
            let id = ReferenceBubbleID(rawValue: index + 1)
            world.addBubble(try ReferenceBubble(id: id, center: item.1, mass: max(1, item.2 * item.2 * 0.02), targetRadius: item.2))
            values[id] = item.0
        }
        addWalls(to: &world)
        let local = [ReferenceVector2(x: -46, y: 34), .init(x: 46, y: 34), .init(x: 0, y: -52)]
        let ids = [5, 6, 7].map(ReferenceSegmentID.init(rawValue:))
        let vertices = polygonVertices(localVertices: local, center: initialPolygonCenter)
        for index in vertices.indices {
            world.addSegment(.kinematicSegment(id: ids[index], previousA: vertices[index], previousB: vertices[(index + 1) % 3], currentA: vertices[index], currentB: vertices[(index + 1) % 3], ownerID: 100, collisionMode: .twoSided))
        }
        return .init(world: world, polygonOwnerID: 100, polygonSegmentIDs: ids, polygonLocalVertices: local, valuesByBubbleID: values)
    }

    private static func addWalls(to world: inout ReferenceWorld) {
        world.addSegment(.staticSegment(id: .init(rawValue: 1), a: .init(x: 0, y: 0), b: .init(x: 0, y: 700), collisionMode: .oneSided(allowedSide: -1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 2), a: .init(x: 375, y: 0), b: .init(x: 375, y: 700), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 3), a: .init(x: 0, y: 0), b: .init(x: 375, y: 0), collisionMode: .oneSided(allowedSide: 1)))
        world.addSegment(.staticSegment(id: .init(rawValue: 4), a: .init(x: 0, y: 700), b: .init(x: 375, y: 700), collisionMode: .oneSided(allowedSide: -1)))
    }

    public static func polygonVertices(localVertices: [ReferenceVector2], center: ReferenceVector2) -> [ReferenceVector2] { localVertices.map { center + $0 } }
    public static func triangleVertices(localVertices: [ReferenceVector2], at time: Double) -> [ReferenceVector2] { polygonVertices(localVertices: localVertices, center: initialPolygonCenter) }
}
