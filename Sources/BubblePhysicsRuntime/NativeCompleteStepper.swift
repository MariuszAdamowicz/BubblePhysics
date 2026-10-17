import BubblePhysicsModel
import BubblePhysicsNativeMetal
import Metal

@MainActor
package final class NativeCompleteStepper: CompleteStepper {
    private let native: NativePublicWorld?
    package init(device: MTLDevice?) throws { native = try device.map { try NativePublicWorld(device: $0) } }

    package func validate(_ change: StagedWorldChange) throws {
        func role(_ id: ObjectID, _ role: MotionRole, polygon: Bool) throws {
            // Wszystkie role fizyczne mają kontroler; brak aktywnego celu oznacza spoczynek.
        }
        func descriptor(_ value: WorldObject) throws {
            switch value {
            case .polygon(let p): try role(p.id, p.motionRole, polygon: true)
            case .bubble(let b): try role(b.id, b.motionRole, polygon: false)
            default: break
            }
        }
        for (index, operation) in change.operations.enumerated() {
            do {
                switch operation {
                case .add(let value), .replace(_, let value): try descriptor(value)
                case .replacePolygons(_, let results): for p in results { try descriptor(.polygon(p)) }
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
                        if case .polygon = object.descriptor { try role(id, value, polygon: true) }
                        else { try role(id, value, polygon: false) }
                    }
                case .updatePhysicsMaterial(let id, let material):
                    if material.friction != 0 { throw TransactionRejectionReason.unsupportedPhysicsParameter(id, .friction) }
                    if material.restitution != 0 { throw TransactionRejectionReason.unsupportedPhysicsParameter(id, .restitution) }
                    if material.kind == .polygon && material.deformability != 0 {
                        throw TransactionRejectionReason.unsupportedPhysicsParameter(id, .deformability)
                    }
                case .startTransition(let transition):
                    if case .physicsMaterial(let id, let parameter) = transition.target,
                       case .scalar(let value) = transition.value, value > 0,
                       parameter == .friction || parameter == .restitution || (parameter == .deformability && change.state.physicsMaterials[id]?.kind == .polygon) {
                        throw TransactionRejectionReason.unsupportedPhysicsParameter(id, parameter)
                    }
                default: break
                }
            } catch let reason as TransactionRejectionReason {
                throw TransactionRejection(operationIndex: index, reason: reason)
            }
        }
    }

    package func completeStep(_ batch: StagedTransactionBatch, duration: Double) async throws -> CompletedRuntimeStep {
        var state = batch.state
        try MotionControllers.prepare(&state, duration: duration)
        // Pusty świat i nieruchome niekolizyjne obiekty nie wymagają wykonania GPU.
        guard state.objects.values.contains(where: { $0.mass != nil }) else { return .init(state: state) }
        guard let native else { throw NativeRuntimeError.deviceUnavailable }
        let input = state.objects.values.map { object in
            var value = NativePublicObject(descriptor: object.descriptor)
            value.position = object.position; value.previousPosition = object.previousPosition
            value.velocity = object.velocity; value.rotation = object.rotation
            value.angularVelocity = object.angularVelocity; value.motionRole = object.motionRole
            value.collisionRadius = object.collisionRadius; value.rigidity = object.rigidity
            return value
        }
        let frame = try await native.step(objects: input, materials: state.physicsMaterials,
            styles: state.renderStyles, region: state.configuration.simulationRegion, duration: duration)
        RegionPolicy.remove(Set(state.objects.keys).subtracting(frame.objects.keys), from: &state)
        for (id, object) in frame.objects {
            state.objects[id]?.position = object.position
            state.objects[id]?.previousPosition = object.previousPosition
            state.objects[id]?.velocity = object.velocity
            state.objects[id]?.rotation = object.rotation
            state.objects[id]?.angularVelocity = object.angularVelocity
            state.objects[id]?.effectiveRadius = object.effectiveRadius
        }
        let feedback = MotionControllers.feedback(&state, contacts: frame.contacts)
        return .init(state: state, driveFeedback: feedback)
    }
}

private enum NativeRuntimeError: Error { case deviceUnavailable }
