import BubblePhysics
import Metal
import XCTest

/// Wspólne budowniczowie małych scen fizyki dla testów etapu 2 (filtry, kinematyka, zdarzenia kontaktu).
/// Kroki idą jedno po drugim przez publiczne `BubbleWorld.advance`, więc `frame.events` nie zawiera duplikatów.
enum SceneBuilders {
    static let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    static let polygonMaterial = PhysicsMaterialID(rawValue: 2)
    static let style = RenderStyleID(rawValue: 1)
    static let step = 1.0 / 60

    @MainActor
    static func makeWorld(device: MTLDevice, region: WorldRectangle? = nil,
                          gravity: WorldPoint = .zero, eventBufferCapacity: Int = 1024) throws -> BubbleWorld {
        try BubbleWorld(configuration: WorldConfiguration(simulationRegion: region ?? WorldRectangle(min: [0, 0], max: [600, 300]), fixedTimeStep: step,
            eventBufferCapacity: eventBufferCapacity, globalForce: gravity), device: device)
    }

    static func baseTransaction(friction: Float = 0) throws -> WorldTransaction {
        try WorldTransaction()
            .updatePhysicsMaterial(bubbleMaterial, material: PhysicsMaterial(kind: .bubble, friction: friction))
            .updatePhysicsMaterial(polygonMaterial, material: PhysicsMaterial(kind: .rigid, friction: friction))
            .updateRenderStyle(style, style: RenderStyle())
    }

    static func bubble(_ id: UInt64, at position: WorldPoint, radius: Float = 8, velocity: WorldPoint = .zero,
                       filter: CollisionFilter = .default, interest: EventInterest = [],
                       mergeGroups: MergeGroupSet = []) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: ObjectID(rawValue: id), position: position, velocity: velocity,
            targetRadius: radius, physicsMaterialID: bubbleMaterial, renderStyleID: style, mergeGroups: mergeGroups,
            eventInterest: interest, filter: filter))
    }

    static func box(_ id: UInt64, at center: WorldPoint, half: WorldPoint, role: MotionRole = .static,
                    velocity: WorldPoint = .zero, filter: CollisionFilter = .default,
                    interest: EventInterest = []) throws -> WorldObject {
        let width = 2 * half.x, height = 2 * half.y
        return .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: id),
            vertices: [[-half.x, -half.y], [half.x, -half.y], [half.x, half.y], [-half.x, half.y]], position: center,
            velocity: velocity, mass: 1, momentOfInertia: (width * width + height * height) / 12, motionRole: role,
            physicsMaterialID: polygonMaterial, renderStyleID: style, eventInterest: interest, filter: filter))
    }

    /// Wykonuje `count` kroków i zwraca ostatnią klatkę oraz wszystkie zdarzenia i potwierdzenia po kolei.
    @MainActor
    static func advance(_ world: BubbleWorld, steps count: Int,
                        each: (Int, WorldFrame) -> Void = { _, _ in }) async -> (frame: WorldFrame, events: [WorldEvent]) {
        var frame = WorldFrame(transactionReceipts: [], events: [])
        var events: [WorldEvent] = []
        for index in 0..<count {
            frame = await world.advance(by: step)
            events += frame.events
            each(index, frame)
        }
        return (frame, events)
    }

    static func began(_ events: [WorldEvent]) -> [(a: ObjectID, b: ObjectID, point: WorldPoint, normal: WorldPoint, impulse: Float)] {
        events.compactMap { if case .contactBegan(let a, let b, let point, let normal, let impulse) = $0 { return (a, b, point, normal, impulse) }; return nil }
    }

    static func ended(_ events: [WorldEvent]) -> [(ObjectID, ObjectID)] {
        events.compactMap { if case .contactEnded(let a, let b) = $0 { return (a, b) }; return nil }
    }

    static func isPair(_ a: ObjectID, _ b: ObjectID, _ x: UInt64, _ y: UInt64) -> Bool {
        (a.rawValue == x && b.rawValue == y) || (a.rawValue == y && b.rawValue == x)
    }
}
