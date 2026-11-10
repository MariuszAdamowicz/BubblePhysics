import BubblePhysicsModel
import BubblePhysicsNativeMetal
import Metal

@MainActor
package final class NativeCompleteStepper: CompleteStepper {
    private let native: NativePublicWorld?
    private var previousBlockers: [ObjectID: ObjectID] = [:]
    /// Pary z dostarczonym `contactBegan` i bez dostarczonego `contactEnded` (zdarzenia kontaktu, etap 2).
    private var previousContacts: Set<ContactPair> = []
    /// Historia policzona w ostatnim kroku; wchodzi do `previousBlockers` i `previousContacts` dopiero w `didPublish`,
    /// więc krok lub klatka odrzucone przez świat zostawiają stepper bez zmian.
    private var candidateHistory: (blockers: [ObjectID: ObjectID], contacts: Set<ContactPair>)?
    package init(device: MTLDevice?, configuration: NativeMetalConfiguration = .default) throws {
        native = try device.map { try NativePublicWorld(device: $0, configuration: configuration) }
    }
    /// Pary z dostarczonym `contactBegan` po ostatnio opublikowanym kroku; szew testów `didPublish`.
    package var publishedContactPairs: Set<ContactPair> { previousContacts }
    package var publishedRenderHandoff: NativeMetalRenderHandoff? { native?.publishedRenderHandoff }
    package var publishedTelemetry: NativeMetalFrameTelemetry? { native?.publishedTelemetry }
    package var publishedContourCPUReadbackCount: Int { native?.publishedContourCPUReadbackCount ?? 0 }
    package var publishedFrameProfile: NativeMetalFrameProfile? { native?.lastPublishedProfile }

    package func validate(_ change: StagedWorldChange) throws {
        func role(_ id: ObjectID, _ role: MotionRole, polygon: Bool) throws {
            // Wszystkie role fizyczne mają kontroler; brak aktywnego celu oznacza spoczynek.
        }
        func descriptor(_ value: WorldObject) throws {
            switch value {
            case .rigidBody(let p): try role(p.id, p.motionRole, polygon: true)
            case .bubble(let b): try role(b.id, b.motionRole, polygon: false)
            default: break
            }
        }
        for (index, operation) in change.operations.enumerated() {
            do {
                switch operation {
                case .add(let value), .replace(_, let value): try descriptor(value)
                case .replaceRigidBodies(_, let results): for p in results { try descriptor(.rigidBody(p)) }
                case .mergeBubbles(_, let result):
                    guard result.motionRole == .dynamic || result.motionRole == .static else {
                        throw TransactionRejectionReason.unsupportedMotionRole(result.id, result.motionRole)
                    }
                case .splitBubble(_, let first, let second):
                    for result in [first.result, second.result] where result.motionRole != .dynamic && result.motionRole != .static {
                        throw TransactionRejectionReason.unsupportedMotionRole(result.id, result.motionRole)
                    }
                case .setMotion(let id, let value):
                    if let object = change.state.objects[id] {
                        if case .rigidBody = object.descriptor { try role(id, value, polygon: true) }
                        else { try role(id, value, polygon: false) }
                    }
                case .updatePhysicsMaterial(let id, let material):
                    if material.kind == .rigid && material.deformability != 0 {
                        throw TransactionRejectionReason.unsupportedPhysicsParameter(id, .deformability)
                    }
                case .startTransition(let transition):
                    if case .physicsMaterial(let id, let parameter) = transition.target,
                       case .scalar(let value) = transition.value, value > 0,
                       parameter == .deformability && change.state.physicsMaterials[id]?.kind == .rigid {
                        throw TransactionRejectionReason.unsupportedPhysicsParameter(id, parameter)
                    }
                default: break
                }
            } catch let reason as TransactionRejectionReason {
                throw TransactionRejection(operationIndex: index, reason: reason)
            }
        }
    }

    /// Uczestnicy historii kontaktów, których nie ma już w stanie: usunięci, scaleni, podzieleni albo poza regionem.
    private func removedContactObjects(in state: RuntimeState) -> Set<ObjectID> {
        var removed = Set<ObjectID>()
        for pair in previousContacts {
            if state.objects[pair.first] == nil { removed.insert(pair.first) }
            if state.objects[pair.second] == nil { removed.insert(pair.second) }
        }
        return removed
    }

    package func completeStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                              commandBuffer: MTLCommandBuffer?,
                              beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        try await performStep(batch, duration: duration, hitTests: hitTests, commandBuffer: commandBuffer,
                              beforeCommit: beforeCommit)
    }

    package func didPublish(_ step: CompletedRuntimeStep) {
        guard let candidateHistory else { return }
        previousBlockers = candidateHistory.blockers
        previousContacts = candidateHistory.contacts
        self.candidateHistory = nil
    }

    private func performStep(_ batch: StagedTransactionBatch, duration: Double, hitTests: [WorldPoint],
                             commandBuffer: MTLCommandBuffer?,
                             beforeCommit: ((NativeMetalRenderHandoff?, RuntimeState) throws -> Void)?) async throws -> CompletedRuntimeStep {
        candidateHistory = nil
        var state = batch.state
        try MotionControllers.prepare(&state, duration: duration)
        let renderPreparedState = state
        // Po usunięciu ostatniego ciała potrzebna jest jedna klatka GPU, aby
        // opublikować exit i wyczyścić poprzednie pary sensora.
        guard state.objects.values.contains(where: { $0.mass != nil }) || native?.hasSensorPairHistory == true else {
            // Bez kroku GPU pary usuniętych obiektów i tak dostają koniec kontaktu.
            // Bez bańki i bryły nie ma czego trafić: każdy punkt hit-testu daje puste miejsce.
            let noHits = [ObjectID?](repeating: nil, count: hitTests.count)
            guard !previousContacts.isEmpty else {
                return .init(state: state, hitTestResults: noHits, snappedObjectIDs: batch.appearedObjectIDs)
            }
            let discrete = EventCompactor.finish([], overflow: WorldEventOverflow(), feedback: [], state: state,
                previousBlockers: previousBlockers, previousContacts: previousContacts,
                removedObjects: removedContactObjects(in: state))
            candidateHistory = (previousBlockers, discrete.contacts)
            return .init(state: state, events: discrete.events, eventOverflow: discrete.overflow, hitTestResults: noHits,
                         snappedObjectIDs: batch.appearedObjectIDs)
        }
        guard let native else { throw NativeRuntimeError.deviceUnavailable }
        let input = state.objects.values.map { object in
            var value = NativePublicObject(descriptor: object.descriptor)
            value.position = object.position; value.previousPosition = object.previousPosition
            value.velocity = object.velocity; value.rotation = object.rotation
            value.angularVelocity = object.angularVelocity; value.motionRole = object.motionRole
            value.collisionRadius = object.collisionRadius; value.rigidity = object.rigidity
            value.structuralShape = object.structuralShape; value.layer = object.layer
            return value
        }
        let frame = try await native.step(objects: input, materials: state.physicsMaterials,
            region: state.configuration.simulationRegion, duration: duration,
            joints: Array(state.joints.values), hitTests: hitTests,
            eventBufferCapacity: state.configuration.eventBufferCapacity,
            commandBuffer: commandBuffer,
            beforeCommit: beforeCommit.map { callback in
                { handoff in try callback(handoff, renderPreparedState) }
            })
        // Solver zwraca podzbiór obiektów wejścia, więc przy równej liczbie nikt nie wypadł z regionu.
        if frame.objects.count != state.objects.count {
            RegionPolicy.remove(Set(state.objects.keys).subtracting(frame.objects.keys), from: &state)
        }
        for (id, object) in frame.objects { state.objects[id]?.adopt(object) }
        let feedback = MotionControllers.feedback(&state, contacts: frame.contacts)
        let discrete = EventCompactor.finish(frame.events, overflow: frame.eventOverflow,
            feedback: feedback, state: state, previousBlockers: previousBlockers,
            previousContacts: previousContacts, removedObjects: removedContactObjects(in: state))
        candidateHistory = (discrete.blockers, discrete.contacts)
        return .init(state: state, events: discrete.events, eventOverflow: discrete.overflow,
            driveFeedback: feedback, contactCandidateOverflowCount: frame.contactCandidateOverflowCount,
            maximumContactCandidatesPerObject: frame.maximumContactCandidatesPerObject,
            hitTestResults: frame.hitTestResults,
            snappedObjectIDs: batch.appearedObjectIDs.union(frame.wrappedObjectIDs))
    }
}

extension RuntimeObject {
    /// Wynik kroku solvera zapisany jednym dostępem do rekordu; kształt strukturalny zostaje zużyty.
    fileprivate mutating func adopt(_ object: NativePublicObject) {
        position = object.position
        previousPosition = object.previousPosition
        velocity = object.velocity
        rotation = object.rotation
        angularVelocity = object.angularVelocity
        effectiveRadius = object.effectiveRadius
        bounds = object.bounds
        structuralShape = nil
    }
}

extension RuntimeState {
    /// Stan bańek i brył po ostatnim kroku, z rekordów, bez odczytu konturów. Czujniki i pola sił nie mają stanu.
    package func publishedObjectStates() -> [ObjectID: ObjectState] {
        var result: [ObjectID: ObjectState] = [:]
        result.reserveCapacity(objects.count)
        for (id, object) in objects {
            let kind: ObjectState.Kind
            let bounds: WorldRectangle
            switch object.descriptor {
            case .bubble:
                kind = .bubble(effectiveRadius: object.effectiveRadius)
                // `effectiveRadius` to minimalna odległość konturu od środka, więc nie obejmuje zdeformowanego konturu;
                // bez AABB z solvera obwiednię daje większy z promieni kolizji i docelowego.
                let r = max(object.collisionRadius, object.targetRadius)
                bounds = object.bounds ?? WorldRectangle(uncheckedMin: object.position - SIMD2(r, r),
                                                         max: object.position + SIMD2(r, r))
            case .rigidBody(let body):
                switch body.shape {
                case .polygon(let geometry):
                    kind = .polygon
                    bounds = Self.polygonBounds(geometry, position: object.position, rotation: object.rotation)
                case .circle(let radius):
                    kind = .circle(radius: radius)
                    bounds = Self.capsuleBounds(halfLength: 0, radius: radius, position: object.position, rotation: object.rotation)
                case .capsule(let halfLength, let radius):
                    kind = .capsule(halfLength: halfLength, radius: radius)
                    bounds = Self.capsuleBounds(halfLength: halfLength, radius: radius, position: object.position, rotation: object.rotation)
                }
            case .sensor, .forceField: continue
            }
            result[id] = ObjectState(kind: kind, position: object.position, velocity: object.velocity,
                rotation: object.rotation, angularVelocity: object.angularVelocity, bounds: bounds)
        }
        return result
    }

    /// Odcinek osi kapsuły (dla koła zerowy) powiększony o promień.
    private static func capsuleBounds(halfLength: Float, radius: Float, position: WorldPoint,
                                      rotation: Float) -> WorldRectangle {
        let end = SIMD2<Float>(abs(cos(rotation)), abs(sin(rotation))) * halfLength + SIMD2(repeating: radius)
        return WorldRectangle(uncheckedMin: position - end, max: position + end)
    }

    private static func polygonBounds(_ geometry: PolygonGeometry, position: WorldPoint,
                                      rotation: Float) -> WorldRectangle {
        let c = cos(rotation), s = sin(rotation)
        var low = SIMD2<Float>(repeating: .infinity), high = SIMD2<Float>(repeating: -.infinity)
        for vertex in geometry.vertices {
            let point = WorldPoint(vertex.x * c - vertex.y * s, vertex.x * s + vertex.y * c) + position
            low = pointwiseMin(low, point); high = pointwiseMax(high, point)
        }
        return WorldRectangle(uncheckedMin: low, max: high)
    }
}

private enum NativeRuntimeError: Error { case deviceUnavailable }
