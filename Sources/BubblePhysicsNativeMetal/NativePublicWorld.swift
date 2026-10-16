import Foundation
import Metal
import BubblePhysicsModel
import BubblePhysicsReference

/// Niepubliczna granica modelu i GPU. ID pozostaje identyfikatorem gry, nigdy indeksem bufora.
package struct NativePublicObject: Sendable {
    package let descriptor: WorldObject
    package var position: WorldPoint
    package var previousPosition: WorldPoint
    package var velocity: WorldPoint
    package var rotation: Float
    package var angularVelocity: Float
    package var motionRole: MotionRole

    package init(descriptor: WorldObject) {
        self.descriptor = descriptor
        switch descriptor {
        case .bubble(let b):
            position = b.position; velocity = b.velocity; rotation = 0; angularVelocity = 0; motionRole = b.motionRole
        case .polygon(let p):
            position = p.position; velocity = p.velocity; rotation = p.rotation
            angularVelocity = p.angularVelocity; motionRole = p.motionRole
        case .sensor(let s):
            position = s.position; velocity = .zero; rotation = s.rotation; angularVelocity = 0; motionRole = .static
        case .forceField(let f):
            position = f.position; velocity = .zero; rotation = f.rotation; angularVelocity = 0; motionRole = .static
        }
        previousPosition = position
    }
}

package struct NativePublicFrame {
    package var objects: [ObjectID: NativePublicObject]
    package let presentation: [ObjectID: [ParameterID: Float]]
    package let profile: NativeMetalFrameProfile
}

struct NativePublicProperties: Equatable, Sendable {
    var flags: SIMD4<UInt32> // enabled, static, wrap, region result (0 unchanged, 1 removed, 2 wrapped)
    var material: SIMD4<Float> // damping, reserved; podatność kontaktów należy do Task 5B
    var resources: SIMD2<UInt64> // material ID, style ID
}

struct NativePublicSettings: Equatable, Sendable {
    var properties: [ReferenceBubbleID: NativePublicProperties]
    var region: WorldRectangle
}

/// Adapter używa trwałego solvera; pełna publikacja następuje dopiero po powodzeniu GPU.
@MainActor
package final class NativePublicWorld {
    private let solver: NativeMetalSolver
    private var polygons: [ObjectID: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [ReferenceSegment])] = [:]
    private var nextSegmentID = 1

    package init(device: MTLDevice) throws { solver = try NativeMetalSolver(device: device) }

    package func step(objects: [NativePublicObject], materials: [PhysicsMaterialID: PhysicsMaterial],
                      styles: [RenderStyleID: RenderStyle], region: WorldRectangle, duration: Double) async throws -> NativePublicFrame {
        let dt = Float(duration)
        guard dt.isFinite, dt > 0, Double(dt) > 0 else { throw NativeMetalSolverError.invalidSnapshot }
        var world = ReferenceWorld(configuration: .init(timeStep: dt, linearDamping: 0, angularDamping: 0),
                                   broadPhase: BruteForceBroadPhase())
        var properties: [ReferenceBubbleID: NativePublicProperties] = [:]
        var candidatePolygons: [ObjectID: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [ReferenceSegment])] = [:]
        var candidateNextSegmentID = nextSegmentID
        var result = Dictionary(uniqueKeysWithValues: objects.map { ($0.descriptor.id, $0) })
        var presentation: [ObjectID: [ParameterID: Float]] = [:]
        for object in objects.sorted(by: { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }) {
            let styleID: RenderStyleID
            let local: PresentationParameters
            switch object.descriptor {
            case .bubble(let b):
                guard let material = materials[b.physicsMaterialID], material.friction == 0, material.restitution == 0,
                      material.deformability == 0,
                      object.motionRole == .dynamic || object.motionRole == .static else { throw NativeMetalSolverError.invalidSnapshot }
                let id = ReferenceBubbleID(rawValue: Int(bitPattern: UInt(b.id.rawValue)))
                var bubble = try ReferenceBubble(id: id, center: .init(x: object.position.x, y: object.position.y),
                    velocity: .init(x: object.velocity.x, y: object.velocity.y), mass: b.mass, targetRadius: b.targetRadius,
                    stiffness: 1, rotation: object.rotation, angularVelocity: object.angularVelocity)
                bubble.previousCenter = .init(x: object.previousPosition.x, y: object.previousPosition.y)
                if object.motionRole == .static { bubble.inverseMass = 0 }
                world.addBubble(bubble)
                properties[id] = NativePublicProperties(
                    flags: SIMD4(1, object.motionRole == .static ? 1 : 0, b.regionExitPolicy == .wrap ? 1 : 0, 0),
                    material: SIMD4(material.damping, 0, 0, 0),
                    resources: SIMD2(b.physicsMaterialID.rawValue, b.renderStyleID.rawValue))
                styleID = b.renderStyleID; local = b.presentation
            case .polygon(let p):
                guard object.motionRole == .static else { throw NativeMetalSolverError.invalidSnapshot }
                let entry: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [ReferenceSegment])
                if let cached = polygons[p.id], cached.geometry == p.geometry,
                   cached.position == object.position, cached.rotation == object.rotation { entry = cached }
                else {
                    let c = cos(object.rotation), s = sin(object.rotation)
                    let points = p.geometry.vertices.map { WorldPoint($0.x * c - $0.y * s, $0.x * s + $0.y * c) + object.position }
                    var segments: [ReferenceSegment] = []
                    for i in points.indices {
                        guard candidateNextSegmentID < Int.max else { throw NativeMetalSolverError.capacityOverflow }
                        let a = points[i], b = points[(i + 1) % points.count]
                        segments.append(.staticSegment(id: .init(rawValue: candidateNextSegmentID),
                            a: .init(x: a.x, y: a.y), b: .init(x: b.x, y: b.y), ownerID: Int(bitPattern: UInt(p.id.rawValue))))
                        candidateNextSegmentID += 1
                    }
                    entry = (p.geometry, object.position, object.rotation, segments)
                }
                candidatePolygons[p.id] = entry
                for segment in entry.segments { world.addSegment(segment) }
                styleID = p.renderStyleID; local = p.presentation
            case .sensor(let s): styleID = s.renderStyleID; local = s.presentation
            case .forceField(let f): styleID = f.renderStyleID; local = f.presentation
            }
            guard let style = styles[styleID] else { throw NativeMetalSolverError.invalidSnapshot }
            presentation[object.descriptor.id] = style.resolvedChannels(overrides: local)
        }
        let frame = try await solver.executePublicFrame(world: world,
            settings: NativePublicSettings(properties: properties, region: region))
        for bubble in frame.bubbles {
            let id = ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue)))
            if frame.regionRemovals.contains(bubble.id) { result.removeValue(forKey: id); presentation.removeValue(forKey: id); continue }
            result[id]?.position = [bubble.center.x, bubble.center.y]
            result[id]?.previousPosition = [bubble.previousCenter.x, bubble.previousCenter.y]
            result[id]?.velocity = [bubble.velocity.x, bubble.velocity.y]
            result[id]?.rotation = bubble.rotation
            result[id]?.angularVelocity = bubble.angularVelocity
        }
        solver.acknowledgePublication()
        polygons = candidatePolygons
        nextSegmentID = candidateNextSegmentID
        return NativePublicFrame(objects: result, presentation: presentation, profile: frame.profile)
    }
}
