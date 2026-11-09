import Foundation
import Metal
import BubblePhysicsModel

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
    /// AABB zdeformowanego konturu bańki po ostatnim kroku (z kernelu); `nil` dla brył i przed pierwszym krokiem.
    package var bounds: WorldRectangle?
    package var rigidity: Float = 0
    package var structuralShape: NativeStructuralShape?
    /// Warstwa rysowania i hit-testu; w rekordzie bańki i bryły jako `filter.w`.
    package var layer: Int32 = 0

    package init(descriptor: WorldObject) {
        self.descriptor = descriptor
        switch descriptor {
        case .bubble(let b):
            position = b.position; velocity = b.velocity; rotation = 0; angularVelocity = 0; motionRole = b.motionRole
            collisionRadius = b.targetRadius; effectiveRadius = b.targetRadius
        case .rigidBody(let p):
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
    package let profile: NativeMetalFrameProfile
    package var contacts: [ObjectID: [DriveBlockingContact]] = [:]
    package var events: [WorldEvent] = []
    package var eventOverflow = WorldEventOverflow()
    package var contactCandidateOverflowCount = 0
    package var maximumContactCandidatesPerObject = 0
    /// Wynik dla każdego punktu hit-testu, w kolejności punktów; `nil` oznacza puste miejsce.
    package var hitTestResults: [ObjectID?] = []
    /// Obiekty, które w tym kroku zawinęły się przez region; niezależnie od zainteresowania `didWrap`.
    package var wrappedObjectIDs: Set<ObjectID> = []
}

struct NativePublicProperties: Equatable, Sendable {
    var flags: SIMD4<UInt32> // enabled, static, wrap, region result (0 unchanged, 1 removed, 2 wrapped)
    var material: SIMD4<Float> // damping, deformability, rigidity, friction
    var restitution: Float
    var resources: SIMD2<UInt64> // material ID, render material ID
    var eventData: SIMD2<UInt64> // interest, merge groups
    var filter: CollisionFilter = .default
    /// Limity prędkości z materiału: liniowa, kątowa (0 = bez limitu); w rekordzie bańki jako `deformation.zw`.
    var speedLimits: SIMD2<Float> = .zero
    /// Warstwa obiektu; w rekordzie bańki jako `filter.w` (`NativeMetalFilter.encodeLayer`).
    var layer: Int32 = 0
}

struct NativePublicSettings: Equatable, Sendable {
    var properties: [NativeSolverBubbleID: NativePublicProperties]
    var region: WorldRectangle
    var rigidPolygons: [NativeRigidPolygonInput] = []
    var eventBufferCapacity = 1024
    var sensors: [SensorDescriptor] = []
    var structuralShapes: [ObjectID: NativeStructuralShape] = [:]
    var staticPolygonMaterials: [ObjectID: PhysicsMaterial] = [:]
    var joints: [Joint] = []
}

/// Adapter używa trwałego solvera; pełna publikacja następuje dopiero po powodzeniu GPU.
@MainActor
package final class NativePublicWorld {
    private let solver: NativeMetalSolver
    private var polygons: [ObjectID: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [NativeSolverSegment])] = [:]
    private var nextSegmentID = 1
    private var publishedProfile: NativeMetalFrameProfile?
    /// Pary z zainteresowaniem kontaktem, które stykały się po ostatnim opublikowanym kroku.
    /// Podział odpowiedzialności za `contactEnded` przy znikającym obiekcie: tu koniec powstaje z samego braku pary w
    /// kontaktach kroku (obiekt zniknął przed krokiem GPU albo w nim); `EventCompactor` ma własną historię i
    /// `removedObjects`, które domykają obiekty znikające dopiero po kroku (np. polityka regionu) i czyszczą historię
    /// w kroku bez GPU. Zduplikowany koniec odfiltrowuje historia kompaktora, bo koniec bez pary w historii jest pomijany.
    private var contactHistory: Set<ContactPair> = []

    package init(device: MTLDevice, configuration: NativeMetalConfiguration = .default,
                 commandExecutor: (any NativeMetalCommandExecuting)? = nil) throws {
        solver = try NativeMetalSolver(device: device, commandExecutor: commandExecutor, configuration: configuration)
    }
    package var hasSensorPairHistory: Bool { solver.hasSensorPairHistory }
    package var publishedRenderHandoff: NativeMetalRenderHandoff? { solver.publishedRenderHandoff }
    package var publishedContourCPUReadbackCount: Int { solver.publishedContourCPUReadbackCount }
    package var publishedTelemetry: NativeMetalFrameTelemetry? { solver.publishedSolverFrame?.telemetry }
    package var lastPublishedProfile: NativeMetalFrameProfile? { publishedProfile }
    /// Bajty buforów kontaktów solvera (kandydaci, cache, sąsiedztwo); szew testów pamięci O(n·k).
    package var contactMemoryBytes: Int { solver.contactMemoryBytes }
    /// Bajty pamięci kontaktów brył; szew testów pamięci O(n·k).
    package var rigidContactMemoryBytes: Int { solver.rigidContactMemoryBytes }

    package func step(objects: [NativePublicObject], materials: [PhysicsMaterialID: PhysicsMaterial],
                      region: WorldRectangle, duration: Double,
                      joints: [Joint] = [], hitTests: [WorldPoint] = [], eventBufferCapacity: Int = 1024, commandBuffer: MTLCommandBuffer? = nil,
                      beforeCommit: ((NativeMetalRenderHandoff) throws -> Void)? = nil) async throws -> NativePublicFrame {
        let dt = Float(duration)
        guard dt.isFinite, dt > 0, Double(dt) > 0 else { throw NativeMetalSolverError.invalidSnapshot }
        var solverBubbles: [NativeSolverBubble] = []
        var solverSegments: [NativeSolverSegment] = []
        solverBubbles.reserveCapacity(objects.count)
        var properties: [NativeSolverBubbleID: NativePublicProperties] = [:]
        var candidatePolygons: [ObjectID: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [NativeSolverSegment])] = [:]
        var candidateNextSegmentID = nextSegmentID
        var result = Dictionary(uniqueKeysWithValues: objects.map { ($0.descriptor.id, $0) })
        var rigidPolygons: [NativeRigidPolygonInput] = []
        var structuralShapes: [ObjectID: NativeStructuralShape] = [:]
        for object in objects.sorted(by: { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }) {
            switch object.descriptor {
            case .bubble(let b):
                guard let material = materials[b.physicsMaterialID],
                      object.collisionRadius > 0, object.collisionRadius.isFinite else { throw NativeMetalSolverError.invalidSnapshot }
                let id = NativeSolverBubbleID(rawValue: Int(bitPattern: UInt(b.id.rawValue)))
                guard object.position.isFiniteVector, object.velocity.isFiniteVector, b.mass.isFinite, b.mass > 0,
                      object.rotation.isFinite, object.angularVelocity.isFinite
                else { throw NativeMetalSolverError.invalidSnapshot }
                var bubble = NativeSolverBubble(id: id, center: object.position, previousCenter: object.previousPosition,
                    velocity: object.velocity, mass: b.mass, targetRadius: object.collisionRadius,
                    stiffness: 1, rotation: object.rotation, angularVelocity: object.angularVelocity)
                if object.motionRole == .static { bubble.inverseMass = 0 }
                solverBubbles.append(bubble)
                properties[id] = NativePublicProperties(
                    flags: SIMD4(1, object.motionRole == .static ? 1 : 0, b.regionExitPolicy == .wrap ? 1 : 0, 0),
                    material: SIMD4(material.damping, material.deformability, object.rigidity, material.friction),
                    restitution: material.restitution,
                    resources: SIMD2(b.physicsMaterialID.rawValue, b.renderMaterialID.rawValue),
                    eventData: SIMD2(b.eventInterest.rawValue, b.mergeGroups.rawValue), filter: b.filter,
                    speedLimits: SIMD2(material.maximumLinearSpeed ?? 0, material.maximumAngularSpeed ?? 0),
                    layer: object.layer)
                if let shape = object.structuralShape { structuralShapes[b.id] = shape }
            case .rigidBody(let p):
                guard let material = materials[p.physicsMaterialID] else { throw NativeMetalSolverError.invalidSnapshot }
                rigidPolygons.append(.init(object: object, damping: material.damping,
                    friction: material.friction, restitution: material.restitution,
                    maximumLinearSpeed: material.maximumLinearSpeed ?? 0,
                    maximumAngularSpeed: material.maximumAngularSpeed ?? 0))
                // Statyczne krawędzie zachowują dotychczasowy cache i guardy baniek.
                // Bryły dynamiczne trafiają wyłącznie do obustronnego solvera brył.
                if object.motionRole != .static { break }
                // Statyczne koło i kapsuła nie mają odcinków: bańki widzą je w solverze brył.
                guard case .polygon(let geometry) = p.shape else { break }
                let entry: (geometry: PolygonGeometry, position: WorldPoint, rotation: Float, segments: [NativeSolverSegment])
                if let cached = polygons[p.id], cached.geometry == geometry,
                   cached.position == object.position, cached.rotation == object.rotation { entry = cached }
                else {
                    let c = cos(object.rotation), s = sin(object.rotation)
                    let points = geometry.vertices.map { WorldPoint($0.x * c - $0.y * s, $0.x * s + $0.y * c) + object.position }
                    var segments: [NativeSolverSegment] = []
                    for i in points.indices {
                        guard candidateNextSegmentID < Int.max else { throw NativeMetalSolverError.capacityOverflow }
                        let a = points[i], b = points[(i + 1) % points.count]
                        segments.append(.fixed(id: candidateNextSegmentID, a: a, b: b,
                            ownerID: Int(bitPattern: UInt(p.id.rawValue))))
                        candidateNextSegmentID += 1
                    }
                    entry = (geometry, object.position, object.rotation, segments)
                }
                candidatePolygons[p.id] = entry
                solverSegments.append(contentsOf: entry.segments.map { var segment = $0; segment.filter = p.filter; return segment })
            case .sensor, .forceField: break
            }
        }
        let staticPolygonMaterials = Dictionary(uniqueKeysWithValues: objects.compactMap { object -> (ObjectID, PhysicsMaterial)? in
            guard case .rigidBody(let polygon) = object.descriptor, object.motionRole == .static,
                  let material = materials[polygon.physicsMaterialID] else { return nil }
            return (polygon.id, material)
        })
        solverBubbles.sort { $0.id < $1.id }
        solverSegments.sort { $0.id < $1.id }
        var input = NativeSolverInput(configuration: .init(timeStep: dt, linearDamping: 0, angularDamping: 0),
            bubbles: solverBubbles, segments: solverSegments,
            publicSettings: NativePublicSettings(properties: properties, region: region,
                rigidPolygons: rigidPolygons, eventBufferCapacity: eventBufferCapacity,
                sensors: objects.compactMap { if case .sensor(let sensor) = $0.descriptor { return sensor }; return nil }
                    .sorted { $0.id.rawValue < $1.id.rawValue }, structuralShapes: structuralShapes,
                staticPolygonMaterials: staticPolygonMaterials,
                joints: joints))
        input.hitTests = hitTests
        let frame = try await solver.executeFrame(input: input, scenarioStep: 0,
            commandBuffer: commandBuffer, beforeCommit: beforeCommit)
        for (id, object) in solver.publishedPolygons { result[id] = object }
        for id in solver.removedPolygons { result.removeValue(forKey: id) }
        for bubble in frame.bubbles {
            let id = ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue)))
            if frame.regionRemovals.contains(bubble.id) { result.removeValue(forKey: id); continue }
            result[id]?.position = bubble.center
            result[id]?.previousPosition = bubble.previousCenter
            result[id]?.velocity = bubble.velocity
            result[id]?.rotation = bubble.rotation
            result[id]?.angularVelocity = bubble.angularVelocity
            result[id]?.effectiveRadius = frame.effectiveRadii[bubble.id] ?? bubble.targetRadius
            result[id]?.bounds = frame.bubbleBounds[bubble.id].map {
                WorldRectangle(uncheckedMin: SIMD2($0.x, $0.y), max: SIMD2($0.z, $0.w))
            }
        }
        var contacts = solver.publishedDriveContacts
        func objectID(_ value: Int) -> ObjectID { ObjectID(rawValue: UInt64(bitPattern: Int64(value))) }
        let segmentOwners = Dictionary(uniqueKeysWithValues: candidatePolygons.flatMap { id, polygon in polygon.segments.map { ($0.id, id) } })
        for contact in frame.contacts {
            let first = objectID(contact.bubbleA.rawValue)
            let second = contact.bubbleB.map { objectID($0.rawValue) } ?? contact.segment.flatMap { segmentOwners[$0] }
            guard let second else { continue }
            let normal = contact.normal, point = contact.pointQ
            contacts[first, default: []].append(.init(objectID: second, point: point, normal: normal))
            contacts[second, default: []].append(.init(objectID: first, point: point, normal: -normal))
        }
        var discreteEvents = frame.events
        var dropped = frame.eventOverflow.droppedCount
        func append(_ event: WorldEvent) {
            if discreteEvents.count < eventBufferCapacity { discreteEvents.append(event) }
            else { dropped += 1 }
        }
        let descriptors = Dictionary(uniqueKeysWithValues: objects.map { ($0.descriptor.id, $0.descriptor) })
        var wrappedIDs = Set<ObjectID>()
        for bubble in frame.bubbles {
            let id = ObjectID(rawValue: UInt64(bitPattern: Int64(bubble.id.rawValue)))
            guard let original = descriptors[id], case .bubble(let descriptor) = original else { continue }
            if frame.regionWraps.contains(bubble.id) { wrappedIDs.insert(id) }
            if frame.regionRemovals.contains(bubble.id), descriptor.eventInterest.contains(.didExitSimulationRegion) {
                append(.didExitSimulationRegion(id))
            }
            if frame.regionWraps.contains(bubble.id), descriptor.eventInterest.contains(.didWrap) {
                append(.didWrap(id))
            }
        }
        for object in objects {
            guard case .rigidBody(let descriptor) = object.descriptor else { continue }
            if solver.wrappedPolygons.contains(descriptor.id) { wrappedIDs.insert(descriptor.id) }
            if solver.removedPolygons.contains(descriptor.id), descriptor.eventInterest.contains(.didExitSimulationRegion) {
                append(.didExitSimulationRegion(descriptor.id))
            }
            if solver.wrappedPolygons.contains(descriptor.id), descriptor.eventInterest.contains(.didWrap) {
                append(.didWrap(descriptor.id))
            }
        }
        let interested = Set(objects.compactMap { object -> ObjectID? in
            let interest: EventInterest
            switch object.descriptor {
            case .bubble(let b): interest = b.eventInterest
            case .rigidBody(let p): interest = p.eventInterest
            default: return nil
            }
            return interest.contains(.contact) ? object.descriptor.id : nil
        })
        let transitions = contactTransitions(bubbleContacts: frame.contacts, segmentOwners: segmentOwners,
            rigidContacts: solver.publishedRigidContacts, interested: interested, duration: Double(dt))
        for event in transitions.events { append(event) }
        solver.acknowledgePublication()
        contactHistory = transitions.pairs
        polygons = candidatePolygons
        nextSegmentID = candidateNextSegmentID
        publishedProfile = frame.profile
        return NativePublicFrame(objects: result, profile: frame.profile,
            contacts: contacts, events: discreteEvents, eventOverflow: WorldEventOverflow(droppedCount: dropped),
            contactCandidateOverflowCount: frame.contactCandidateOverflowCount,
            maximumContactCandidatesPerObject: frame.maximumContactCandidatesPerObject,
            hitTestResults: frame.hitTestResults, wrappedObjectIDs: wrappedIDs)
    }

    /// Przejścia kontaktu pary w jednym kroku. Cache baniek i wiersze brył są już odczytane na CPU, więc początek to para
    /// bez kontaktu w poprzednim kroku, a koniec to para z poprzedniego kroku bez kontaktu teraz (w tym z usuniętym
    /// obiektem). Bez atomików i bez słownika w kolejności wyjścia: pary idą posortowane po kluczu, a sumy w kolejności
    /// rekordów, więc wynik jest deterministyczny. Para wchodzi do historii tylko z zainteresowaniem kontaktem.
    /// Punkt jest średnią ważoną wnikaniem, normalna znormalizowaną sumą (od mniejszego `ObjectID` do większego),
    /// a impuls sumą mnożników podzieloną przez krok.
    private func contactTransitions(bubbleContacts: [NativeSolverContact], segmentOwners: [Int: ObjectID],
                                    rigidContacts: [NativeRigidPolygonState.ContactRecord], interested: Set<ObjectID>,
                                    duration: Double) -> (events: [WorldEvent], pairs: Set<ContactPair>) {
        guard !interested.isEmpty || !contactHistory.isEmpty else { return ([], []) }
        struct Sum { var point = SIMD2<Float>.zero, weight: Float = 0, normal = SIMD2<Float>.zero, impulse: Float = 0 }
        var sums: [ContactPair: Sum] = [:]
        func add(_ first: ObjectID, _ second: ObjectID, point: WorldPoint, normalFromFirst: WorldPoint,
                 weight: Float, impulse: Float) {
            guard interested.contains(first) || interested.contains(second) else { return }
            let key = ContactPair(first, second)
            let normal = key.first == first ? normalFromFirst : -normalFromFirst
            var sum = sums[key, default: Sum()]
            sum.point += point * weight; sum.weight += weight; sum.normal += normal; sum.impulse += impulse
            sums[key] = sum
        }
        func objectID(_ value: Int) -> ObjectID { ObjectID(rawValue: UInt64(bitPattern: Int64(value))) }
        let step = Float(duration)
        for contact in bubbleContacts {
            let first = objectID(contact.bubbleA.rawValue)
            guard let second = contact.bubbleB.map({ objectID($0.rawValue) }) ?? contact.segment.flatMap({ segmentOwners[$0] })
            else { continue }
            // Cache trzyma też pary w szczelinie do `separationTolerance`, a po rozwiązaniu `penetration` to nieujemna
            // reszta wnikania, więc styk to reszta wnikania albo aktywny mnożnik, a nie samo trafienie w cache.
            guard contact.penetration > 0 || contact.accumulatedCompression > 0 else { continue }
            // Normalna w cache: bańka–bańka od A do B, bańka–odcinek od odcinka do bańki A.
            add(first, second, point: contact.pointQ, normalFromFirst: contact.bubbleB == nil ? -contact.normal : contact.normal,
                weight: max(contact.penetration, 0) + 1e-4, impulse: contact.accumulatedCompression / step)
        }
        for record in rigidContacts {
            add(record.first, record.second, point: record.point, normalFromFirst: record.normal,
                weight: 1, impulse: record.impulseSum / step)
        }
        let current = Set(sums.keys)
        var events: [WorldEvent] = []
        for key in sums.keys.sorted() where !contactHistory.contains(key) {
            let sum = sums[key]!
            let length = sum.normal.euclideanLength
            events.append(.contactBegan(key.first, key.second,
                point: sum.point / sum.weight, normal: length > 0 ? sum.normal / length : .zero, impulse: sum.impulse))
        }
        for key in contactHistory.sorted() where !current.contains(key) {
            events.append(.contactEnded(key.first, key.second))
        }
        return (events, current)
    }
}
