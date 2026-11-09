import BubblePhysics
import Metal
import XCTest

/// Wspólne budowniczowie małych scen fizyki dla testów etapu 2 (filtry, kinematyka, zdarzenia kontaktu).
/// Kroki idą jedno po drugim przez publiczne `BubbleWorld.advance`, więc `frame.events` nie zawiera duplikatów.
enum SceneBuilders {
    static let bubbleMaterial = PhysicsMaterialID(rawValue: 1)
    static let polygonMaterial = PhysicsMaterialID(rawValue: 2)
    static let style = RenderMaterialID(rawValue: 1)
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
            .updateRenderMaterial(style, material: try RenderMaterial())
    }

    static func bubble(_ id: UInt64, at position: WorldPoint, radius: Float = 8, velocity: WorldPoint = .zero,
                       filter: CollisionFilter = .default, interest: EventInterest = [],
                       mergeGroups: MergeGroupSet = [], role: MotionRole = .dynamic,
                       regionExitPolicy: RegionExitPolicy = .remove,
                       render: RenderMaterialID = style, layer: Int32 = 0, decal: Decal? = nil) throws -> WorldObject {
        .bubble(try BubbleDescriptor(id: ObjectID(rawValue: id), position: position, velocity: velocity,
            targetRadius: radius, motionRole: role, regionExitPolicy: regionExitPolicy, physicsMaterialID: bubbleMaterial, renderMaterialID: render, mergeGroups: mergeGroups,
            eventInterest: interest, filter: filter, layer: layer, decal: decal))
    }

    static func box(_ id: UInt64, at center: WorldPoint, half: WorldPoint, role: MotionRole = .static,
                    velocity: WorldPoint = .zero, filter: CollisionFilter = .default,
                    interest: EventInterest = [], materialID: PhysicsMaterialID? = nil,
                    render: RenderMaterialID = style, layer: Int32 = 0, rotation: Float = 0,
                    decal: Decal? = nil) throws -> WorldObject {
        let width = 2 * half.x, height = 2 * half.y
        return .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: id),
            vertices: [[-half.x, -half.y], [half.x, -half.y], [half.x, half.y], [-half.x, half.y]], position: center,
            rotation: rotation, velocity: velocity, mass: 1, momentOfInertia: (width * width + height * height) / 12,
            motionRole: role, physicsMaterialID: materialID ?? polygonMaterial, renderMaterialID: render,
            eventInterest: interest, filter: filter, layer: layer, decal: decal))
    }

    static func circle(_ id: UInt64, at center: WorldPoint, radius: Float, role: MotionRole = .dynamic,
                       velocity: WorldPoint = .zero, angularVelocity: Float = 0, mass: Float = 1,
                       filter: CollisionFilter = .default, interest: EventInterest = [],
                       materialID: PhysicsMaterialID? = nil,
                       regionExitPolicy: RegionExitPolicy = .remove,
                       render: RenderMaterialID = style, layer: Int32 = 0) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: id), shape: .circle(radius: radius), position: center,
            velocity: velocity, angularVelocity: angularVelocity, mass: mass, motionRole: role,
            regionExitPolicy: regionExitPolicy, physicsMaterialID: materialID ?? polygonMaterial,
            renderMaterialID: render, eventInterest: interest, filter: filter, layer: layer))
    }

    /// Kapsuła o osi wzdłuż lokalnej osi X.
    static func capsule(_ id: UInt64, at center: WorldPoint, halfLength: Float, radius: Float, rotation: Float = 0,
                        role: MotionRole = .dynamic, velocity: WorldPoint = .zero, angularVelocity: Float = 0,
                        mass: Float = 1, filter: CollisionFilter = .default, interest: EventInterest = [],
                        materialID: PhysicsMaterialID? = nil, render: RenderMaterialID = style,
                        layer: Int32 = 0, decal: Decal? = nil) throws -> WorldObject {
        .rigidBody(try RigidBodyDescriptor(id: ObjectID(rawValue: id), shape: .capsule(halfLength: halfLength, radius: radius),
            position: center, rotation: rotation, velocity: velocity, angularVelocity: angularVelocity, mass: mass,
            motionRole: role, physicsMaterialID: materialID ?? polygonMaterial, renderMaterialID: render,
            eventInterest: interest, filter: filter, layer: layer, decal: decal))
    }

    static func distanceJoint(_ id: UInt64, _ a: UInt64, _ b: UInt64? = nil, anchorA: WorldPoint = .zero,
                              anchorB: WorldPoint = .zero, length: Float, softness: Float = 0, damping: Float = 0,
                              collideConnected: Bool = false) throws -> Joint {
        try Joint(id: JointID(rawValue: id), bodyA: ObjectID(rawValue: a), bodyB: b.map { ObjectID(rawValue: $0) },
                  anchorA: anchorA, anchorB: anchorB, kind: .distance(length: length, softness: softness, damping: damping),
                  collideConnected: collideConnected)
    }

    static func hingeJoint(_ id: UInt64, _ a: UInt64, _ b: UInt64? = nil, anchorA: WorldPoint = .zero,
                           anchorB: WorldPoint = .zero, limits: HingeLimits? = nil, motor: HingeMotor? = nil,
                           collideConnected: Bool = false) throws -> Joint {
        try Joint(id: JointID(rawValue: id), bodyA: ObjectID(rawValue: a), bodyB: b.map { ObjectID(rawValue: $0) },
                  anchorA: anchorA, anchorB: anchorB, kind: .hinge(limits: limits, motor: motor),
                  collideConnected: collideConnected)
    }

    static func weldJoint(_ id: UInt64, _ a: UInt64, _ b: UInt64, anchorA: WorldPoint, anchorB: WorldPoint) throws -> Joint {
        try Joint(id: JointID(rawValue: id), bodyA: ObjectID(rawValue: a), bodyB: ObjectID(rawValue: b),
                  anchorA: anchorA, anchorB: anchorB, kind: .weld)
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
