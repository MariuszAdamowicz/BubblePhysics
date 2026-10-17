import Foundation
import Metal
import BubblePhysicsModel
import BubblePhysicsReference

/// Niepubliczna granica modelu i GPU. ID pozostaje identyfikatorem gry, nigdy indeksem bufora.
package struct NativePublicObject: Equatable, Sendable {
    package let descriptor: WorldObject
    package var position: WorldPoint
    package var previousPosition: WorldPoint
    package var velocity: WorldPoint
    package var rotation: Float
    package var angularVelocity: Float
    package var motionRole: MotionRole
    package var collisionRadius: Float = 0
    package var effectiveRadius: Float = 0
    package var rigidity: Float = 0
    package var structuralShape: NativeStructuralShape?
    package var presentation: PresentationParameters = .empty

    package init(descriptor: WorldObject) {
        self.descriptor = descriptor
        switch descriptor {
        case .bubble(let b):
            position = b.position; velocity = b.velocity; rotation = 0; angularVelocity = 0; motionRole = b.motionRole
            collisionRadius = b.targetRadius; effectiveRadius = b.targetRadius
            presentation = b.presentation
        case .polygon(let p):
            position = p.position; velocity = p.velocity; rotation = p.rotation
            angularVelocity = p.angularVelocity; motionRole = p.motionRole
            presentation = p.presentation
        case .sensor(let s):
            position = s.position; velocity = .zero; rotation = s.rotation; angularVelocity = 0; motionRole = .static
            presentation = s.presentation
        case .forceField(let f):
            position = f.position; velocity = .zero; rotation = f.rotation; angularVelocity = 0; motionRole = .static
            presentation = f.presentation
        }
        previousPosition = position
    }
}

package struct NativePublicFrame {
    package var objects: [ObjectID: NativePublicObject]
    package let presentation: [ObjectID: [ParameterID: Float]]
    package let profile: NativeMetalFrameProfile
    package var contacts: [ObjectID: [DriveBlockingContact]] = [:]
    package var events: [WorldEvent] = []
    package var eventOverflow = WorldEventOverflow()
}

struct NativePublicProperties: Equatable, Sendable {
    var flags: SIMD4<UInt32> // enabled, static, wrap, region result (0 unchanged, 1 removed, 2 wrapped)
    var material: SIMD4<Float> // damping, reserved; podatność kontaktów należy do Task 5B
    var resources: SIMD2<UInt64> // material ID, style ID
    var eventData: SIMD2<UInt64> // interest, merge groups
}

struct NativePublicSettings: Equatable, Sendable {
    var properties: [ReferenceBubbleID: NativePublicProperties]
    var region: WorldRectangle
    var rigidPolygons: [NativeRigidPolygonInput] = []
    var eventBufferCapacity = 1024
    var sensors: [SensorDescriptor] = []
    var structuralShapes: [ObjectID: NativeStructuralShape] = [:]
}

/// Adapter używa trwałego solvera; pełna publikacja następuje dopiero po powodzeniu GPU.
@MainActor
package final class NativePublicWorld {
    private let solver: NativeMetalSolver
    private var polygons: [ObjectID: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [ReferenceSegment])] = [:]
    private var nextSegmentID = 1

    package init(device: MTLDevice, configuration: NativeMetalConfiguration = .default) throws {
        solver = try NativeMetalSolver(device: device, configuration: configuration)
    }
    package var hasSensorPairHistory: Bool { solver.hasSensorPairHistory }
    package var publishedRenderHandoff: NativeMetalRenderHandoff? { solver.publishedRenderHandoff }
    package var publishedContourCPUReadbackCount: Int { solver.publishedContourCPUReadbackCount }
    package var publishedTelemetry: NativeMetalFrameTelemetry? { solver.publishedFrame?.telemetry }

    package func step(objects: [NativePublicObject], materials: [PhysicsMaterialID: PhysicsMaterial],
                      styles: [RenderStyleID: RenderStyle], region: WorldRectangle, duration: Double,
                      eventBufferCapacity: Int = 1024, commandBuffer: MTLCommandBuffer? = nil,
                      beforeCommit: ((NativeMetalRenderHandoff) throws -> Void)? = nil) async throws -> NativePublicFrame {
        let dt = Float(duration)
        guard dt.isFinite, dt > 0, Double(dt) > 0 else { throw NativeMetalSolverError.invalidSnapshot }
        var world = ReferenceWorld(configuration: .init(timeStep: dt, linearDamping: 0, angularDamping: 0),
                                   broadPhase: BruteForceBroadPhase())
        var properties: [ReferenceBubbleID: NativePublicProperties] = [:]
        var candidatePolygons: [ObjectID: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [ReferenceSegment])] = [:]
        var candidateNextSegmentID = nextSegmentID
        var result = Dictionary(uniqueKeysWithValues: objects.map { ($0.descriptor.id, $0) })
        var presentation: [ObjectID: [ParameterID: Float]] = [:]
        var rigidPolygons: [NativeRigidPolygonInput] = []
        var structuralShapes: [ObjectID: NativeStructuralShape] = [:]
        for object in objects.sorted(by: { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }) {
            let styleID: RenderStyleID
            let local: PresentationParameters
            switch object.descriptor {
            case .bubble(let b):
                guard let material = materials[b.physicsMaterialID], material.friction == 0, material.restitution == 0,
                      object.collisionRadius > 0, object.collisionRadius.isFinite else { throw NativeMetalSolverError.invalidSnapshot }
                let id = ReferenceBubbleID(rawValue: Int(bitPattern: UInt(b.id.rawValue)))
                var bubble = try ReferenceBubble(id: id, center: .init(x: object.position.x, y: object.position.y),
                    velocity: .init(x: object.velocity.x, y: object.velocity.y), mass: b.mass, targetRadius: object.collisionRadius,
                    stiffness: 1, rotation: object.rotation, angularVelocity: object.angularVelocity)
                bubble.previousCenter = .init(x: object.previousPosition.x, y: object.previousPosition.y)
                if object.motionRole == .static { bubble.inverseMass = 0 }
                world.addBubble(bubble)
                properties[id] = NativePublicProperties(
                    flags: SIMD4(1, object.motionRole == .static ? 1 : 0, b.regionExitPolicy == .wrap ? 1 : 0, 0),
                    material: SIMD4(material.damping, material.deformability, object.rigidity, 0),
                    resources: SIMD2(b.physicsMaterialID.rawValue, b.renderStyleID.rawValue),
                    eventData: SIMD2(b.eventInterest.rawValue, b.mergeGroups.rawValue))
                if let shape = object.structuralShape { structuralShapes[b.id] = shape }
                styleID = b.renderStyleID; local = object.presentation
            case .polygon(let p):
                guard let material = materials[p.physicsMaterialID] else { throw NativeMetalSolverError.invalidSnapshot }
                rigidPolygons.append(.init(object: object, damping: material.damping))
                styleID = p.renderStyleID; local = object.presentation
                // Statyczne krawędzie zachowują dotychczasowy cache i guardy baniek.
                // Bryły dynamiczne trafiają wyłącznie do obustronnego solvera brył.
                if object.motionRole != .static { break }
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
            case .sensor(let s): styleID = s.renderStyleID; local = object.presentation
            case .forceField(let f): styleID = f.renderStyleID; local = object.presentation
            }
            guard let style = styles[styleID] else { throw NativeMetalSolverError.invalidSnapshot }
            presentation[object.descriptor.id] = style.resolvedChannels(overrides: local)
        }
        let frame = try await solver.executePublicFrame(world: world,
            settings: NativePublicSettings(properties: properties, region: region,
                rigidPolygons: rigidPolygons, eventBufferCapacity: eventBufferCapacity,
                sensors: objects.compactMap { if case .sensor(let sensor) = $0.descriptor { return sensor }; return nil }
                    .sorted { $0.id.rawValue < $1.id.rawValue }, structuralShapes: structuralShapes),
            commandBuffer: commandBuffer, beforeCommit: beforeCommit)
        for (id, object) in solver.publishedPolygons { result[id] = object }
        for id in solver.removedPolygons { result.removeValue(forKey: id); presentation.removeValue(forKey: id) }
        for bubble in frame.bubbles {
            let id = ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue)))
            if frame.regionRemovals.contains(bubble.id) { result.removeValue(forKey: id); presentation.removeValue(forKey: id); continue }
            result[id]?.position = [bubble.center.x, bubble.center.y]
            result[id]?.previousPosition = [bubble.previousCenter.x, bubble.previousCenter.y]
            result[id]?.velocity = [bubble.velocity.x, bubble.velocity.y]
            result[id]?.rotation = bubble.rotation
            result[id]?.angularVelocity = bubble.angularVelocity
            result[id]?.effectiveRadius = frame.effectiveRadii[bubble.id] ?? bubble.targetRadius
        }
        var contacts = solver.publishedDriveContacts
        func objectID(_ value: Int) -> ObjectID { ObjectID(rawValue: UInt64(bitPattern: Int64(value))) }
        let segmentOwners = Dictionary(uniqueKeysWithValues: candidatePolygons.flatMap { id, polygon in polygon.segments.map { ($0.id, id) } })
        for contact in frame.contacts {
            let first = objectID(contact.bubbleA.rawValue)
            let second = contact.bubbleB.map { objectID($0.rawValue) } ?? contact.segment.flatMap { segmentOwners[$0] }
            guard let second else { continue }
            let normal = WorldPoint(contact.normal.x, contact.normal.y), point = WorldPoint(contact.pointQ.x, contact.pointQ.y)
            contacts[first, default: []].append(.init(objectID: second, point: point, normal: normal))
            contacts[second, default: []].append(.init(objectID: first, point: point, normal: -normal))
        }
        var discreteEvents = frame.events
        var dropped = frame.eventOverflow.droppedCount
        func append(_ event: WorldEvent) {
            if discreteEvents.count < eventBufferCapacity { discreteEvents.append(event) }
            else { dropped += 1 }
        }
        for bubble in frame.bubbles {
            let id = ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue)))
            guard let original = objects.first(where: { $0.descriptor.id == id }), case .bubble(let descriptor) = original.descriptor else { continue }
            if frame.regionRemovals.contains(bubble.id), descriptor.eventInterest.contains(.didExitSimulationRegion) {
                append(.didExitSimulationRegion(id))
            }
            if frame.regionWraps.contains(bubble.id), descriptor.eventInterest.contains(.didWrap) {
                append(.didWrap(id))
            }
        }
        for object in objects {
            guard case .polygon(let descriptor) = object.descriptor else { continue }
            if solver.removedPolygons.contains(descriptor.id), descriptor.eventInterest.contains(.didExitSimulationRegion) {
                append(.didExitSimulationRegion(descriptor.id))
            }
            if solver.wrappedPolygons.contains(descriptor.id), descriptor.eventInterest.contains(.didWrap) {
                append(.didWrap(descriptor.id))
            }
        }
        solver.acknowledgePublication()
        polygons = candidatePolygons
        nextSegmentID = candidateNextSegmentID
        return NativePublicFrame(objects: result, presentation: presentation, profile: frame.profile,
            contacts: contacts, events: discreteEvents, eventOverflow: WorldEventOverflow(droppedCount: dropped))
    }
}
