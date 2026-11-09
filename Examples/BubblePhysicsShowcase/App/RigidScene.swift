import BubblePhysics
import BubblePhysicsAssets
import Metal

/// Scena brył: koło, kapsuła i wielokąty, trzy rodzaje więzów oraz kinematyczna platforma z dynamiczną bryłą na wierzchu.
/// Dotknięcie bryły podrzuca ją impulsem.
@MainActor
final class RigidScene: ShowcaseScene {
    let configuration: WorldConfiguration
    let clearColor = MTLClearColorMake(0.10, 0.08, 0.10, 1)

    private static let rigidPhysics = PhysicsMaterialID(rawValue: 1)
    private static let wallLook = RenderMaterialID(rawValue: 1)
    private static let platformLook = RenderMaterialID(rawValue: 2)
    private static let bodyLooks = (1...4).map { RenderMaterialID(rawValue: UInt64(10 + $0)) }
    private static let bodyColors: [RGBA] = [
        RGBA(0.95, 0.45, 0.35, 1), RGBA(0.35, 0.80, 0.55, 1), RGBA(0.40, 0.60, 0.95, 1), RGBA(0.95, 0.80, 0.35, 1)
    ]
    private static let platformID = ObjectID(rawValue: 100)
    private static let touchImpulse: Float = 60
    private var dynamicBodies: [ObjectID: Float] = [:]
    private var nextBodyID: UInt64 = 200

    init() throws {
        configuration = try WorldConfiguration(
            simulationRegion: WorldRectangle(min: [0, 0], max: [360, 640]),
            fixedTimeStep: 1.0 / 60, globalForce: [0, -60])
    }

    func prepare(assets: AssetRegistry) throws -> WorldTransaction {
        var transaction = WorldTransaction()
            .updatePhysicsMaterial(Self.rigidPhysics, material: try PhysicsMaterial(
                kind: .rigid, friction: 0.6, restitution: 0.15, maximumLinearSpeed: 120, maximumAngularSpeed: 10))
            .updateRenderMaterial(Self.wallLook, material: try RenderMaterial(color: RGBA(0.30, 0.28, 0.34, 1)))
            .updateRenderMaterial(Self.platformLook, material: try RenderMaterial(color: RGBA(0.85, 0.85, 0.90, 1)))
        for (index, color) in Self.bodyColors.enumerated() {
            transaction = transaction.updateRenderMaterial(Self.bodyLooks[index], material: try RenderMaterial(
                color: color, outline: RenderOutline(color: .white, width: 1.5)))
        }
        for wall in try showcaseWalls(region: configuration.simulationRegion, physics: Self.rigidPhysics,
                                      render: Self.wallLook, firstID: 1) {
            transaction = transaction.add(.rigidBody(wall))
        }
        transaction = try addFreeBodies(to: transaction)
        transaction = try addJointedBodies(to: transaction)
        return try addPlatform(to: transaction)
    }

    /// Koło, kapsuła i trzy wielokąty (prostokąt, trójkąt, pięciokąt) spadają na dno.
    private func addFreeBodies(to start: WorldTransaction) throws -> WorldTransaction {
        let pentagon: [WorldPoint] = (0..<5).map { index in
            let angle = Float(index) * 2 * .pi / 5 + .pi / 2
            return [16 * cos(angle), 16 * sin(angle)]
        }
        let shapes: [(RigidShape, WorldPoint)] = [
            (.circle(radius: 14), [60, 560]), (.capsule(halfLength: 14, radius: 8), [130, 590]),
            (try .polygon(PolygonGeometry(vertices: [[-16, -11], [16, -11], [16, 11], [-16, 11]])), [200, 560]),
            (try .polygon(PolygonGeometry(vertices: [[-16, -12], [16, -12], [0, 18]])), [270, 590]),
            (try .polygon(PolygonGeometry(vertices: pentagon)), [320, 550])
        ]
        var transaction = start
        for (index, entry) in shapes.enumerated() {
            transaction = transaction.add(.rigidBody(try body(entry.0, at: entry.1, look: index)))
        }
        return transaction
    }

    private func body(_ shape: RigidShape, at position: WorldPoint, look: Int, mass: Float = 2) throws -> RigidBodyDescriptor {
        let id = ObjectID(rawValue: nextBodyID)
        nextBodyID += 1
        dynamicBodies[id] = mass
        return try RigidBodyDescriptor(id: id, shape: shape, position: position, mass: mass, motionRole: .dynamic,
                                       physicsMaterialID: Self.rigidPhysics,
                                       renderMaterialID: Self.bodyLooks[look % Self.bodyLooks.count])
    }

    /// Więz dystansowy (wahadło na linie), zawias z zakresem (wahadło na osi w świecie) i spaw (dwa sklejone pudełka).
    private func addJointedBodies(to start: WorldTransaction) throws -> WorldTransaction {
        let box: [WorldPoint] = [[-9, -9], [9, -9], [9, 9], [-9, 9]]
        let bar: [WorldPoint] = [[-40, -4], [40, -4], [40, 4], [-40, 4]]
        let hanging = try body(.polygon(PolygonGeometry(vertices: box)), at: [90, 380], look: 0)
        let swinging = try body(.polygon(PolygonGeometry(vertices: bar)), at: [260, 430], look: 1)
        let left = try body(.polygon(PolygonGeometry(vertices: box)), at: [60, 330], look: 2)
        let right = try body(.polygon(PolygonGeometry(vertices: box)), at: [78, 330], look: 3)
        return try start
            .add(.rigidBody(hanging)).add(.rigidBody(swinging)).add(.rigidBody(left)).add(.rigidBody(right))
            .addJoint(Joint(id: JointID(rawValue: 1), bodyA: hanging.id, anchorB: [90, 460],
                            kind: .distance(length: 80, softness: 0, damping: 0.1)))
            .addJoint(Joint(id: JointID(rawValue: 2), bodyA: swinging.id, anchorA: [-40, 0], anchorB: [220, 430],
                            kind: .hinge(limits: HingeLimits(lower: -1.2, upper: 1.2), motor: nil)))
            .addJoint(Joint(id: JointID(rawValue: 3), bodyA: left.id, bodyB: right.id, anchorA: [9, 0], anchorB: [-9, 0],
                            kind: .weld))
    }

    /// Platforma jedzie w górę i w dół po ścieżce; ma nieskończoną masę, więc unosi bryłę, która na niej leży.
    private func addPlatform(to start: WorldTransaction) throws -> WorldTransaction {
        let points: [WorldPoint] = [[180, 120], [180, 300]]
        let lap: [WorldPoint] = [points[1], points[0]]
        let platform = try RigidBodyDescriptor(
            id: Self.platformID, vertices: [[-40, -5], [40, -5], [40, 5], [-40, 5]], position: points[0],
            motionRole: .kinematic, physicsMaterialID: Self.rigidPhysics, renderMaterialID: Self.platformLook)
        let rider = try body(.polygon(PolygonGeometry(vertices: [[-12, -12], [12, -12], [12, 12], [-12, 12]])),
                             at: [180, 175], look: 2, mass: 3)
        return start
            .add(.rigidBody(platform))
            .setKinematicDrive(Self.platformID, drive: .path(try PathDrive(
                points: Array(repeating: lap, count: 200).flatMap { $0 }, speed: 40)))
            .add(.rigidBody(rider))
    }

    func update(frame: WorldFrame, world: BubbleWorld) {}

    // guide-region: sync-query
    /// Zapytania synchroniczne czytają ostatnio opublikowany stan bez czekania na GPU. Bryły są sprawdzane dokładnie.
    func touchBegan(at point: WorldPoint, world: BubbleWorld) async {
        guard let id = world.objects(at: point).first(where: { dynamicBodies[$0] != nil }),
              let mass = dynamicBodies[id] else { return }
        world.submit(WorldTransaction().applyImpulse(to: id, impulse: [0, mass * Self.touchImpulse]))
    }
    // guide-region-end

    func touchMoved(to point: WorldPoint, world: BubbleWorld) {}
    func touchEnded(world: BubbleWorld) {}
}
