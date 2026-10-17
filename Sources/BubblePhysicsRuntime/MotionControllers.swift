import Foundation
import BubblePhysicsModel

package struct PhysicalTransitionProgress: Equatable, Sendable {
    var initial: TransitionValue
    var elapsed: Double
}

/// Kontrolery dostarczają prędkość/siłę przed krokiem; nigdy nie zapisują osiągniętej pozycji.
package enum MotionControllers {
    static func length(_ v: WorldPoint) -> Float { hypot(v.x, v.y) }

    package static func prepare(_ state: inout RuntimeState, duration: Double) throws {
        try advanceTransitions(&state, duration: duration)
        let dt = Float(duration)
        let fields = state.objects.values.sorted { $0.descriptor.id.rawValue < $1.descriptor.id.rawValue }.compactMap { object -> (RuntimeObject, ForceFieldDescriptor)? in
            if case .forceField(let field) = object.descriptor { return (object, field) }; return nil
        }
        for id in state.objects.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var object = state.objects[id], let mass = object.mass else { continue }
            if case .bubble(let bubble) = object.descriptor {
                let active = object.playerDriveTarget != nil && bubble.drivePolicy.rigidifies
                if active || object.capturedRadius != nil {
                    object.shapeElapsed += duration
                    let seconds = active ? bubble.drivePolicy.rigidificationDuration : bubble.drivePolicy.relaxationDuration
                    let t = seconds == 0 ? Float(1) : Float(min(1, object.shapeElapsed / seconds))
                    let radius = active ? (object.capturedRadius ?? object.targetRadius) : object.targetRadius
                    object.collisionRadius = object.radiusBlendStart + (radius - object.radiusBlendStart) * t
                    object.rigidity = object.rigidityBlendStart + ((active ? 1 : 0) - object.rigidityBlendStart) * t
                    if !active && t == 1 { object.capturedRadius = nil }
                } else { object.collisionRadius = object.targetRadius }
            }
            switch object.motionRole {
            case .static: object.velocity = .zero; object.angularVelocity = 0
            case .dynamic, .motorDriven:
                var force = state.globalForce
                for (source, field) in fields where field.filter.objectIDs?.contains(id) ?? true {
                    force += fieldForce(field, source: source, point: object.position)
                }
                if object.motionRole == .motorDriven, let motor = object.motorDrive {
                    force += motor.force
                    let inertia: Float
                    if case .polygon(let polygon) = object.descriptor { inertia = polygon.momentOfInertia }
                    else { inertia = 0.5 * mass * object.collisionRadius * object.collisionRadius }
                    object.angularVelocity += motor.torque / inertia * dt
                }
                object.velocity += force / mass * dt
            case .playerDriven:
                object.velocity = object.playerDriveTarget.map { velocity(to: $0, from: object.position, speed: 12, dt: dt) } ?? .zero
            case .pathDriven:
                if let path = object.pathDrive, !object.pathStopped {
                    while object.pathIndex < path.points.count - 1 && length(path.points[object.pathIndex] - object.position) <= 0.0001 {
                        object.pathIndex += 1
                    }
                    object.velocity = velocity(to: path.points[object.pathIndex], from: object.position, speed: path.speed, dt: dt)
                } else { object.velocity = .zero; object.angularVelocity = 0 }
            }
            try requireFinite(object.velocity, "motion.velocity")
            try requireFinite(object.angularVelocity, "motion.angularVelocity")
            state.objects[id] = object
        }
    }

    private static func velocity(to target: WorldPoint, from origin: WorldPoint, speed: Float, dt: Float) -> WorldPoint {
        let delta = target - origin, distance = length(delta)
        guard distance > 0 else { return .zero }
        return delta * (min(speed, distance / dt) / distance)
    }

    package static func feedback(_ state: inout RuntimeState, contacts: [ObjectID: [DriveBlockingContact]]) -> [DriveFeedback] {
        var result: [DriveFeedback] = []
        for id in state.objects.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            guard var object = state.objects[id] else { continue }
            let target: WorldPoint
            if object.motionRole == .playerDriven, let point = object.playerDriveTarget { target = point }
            else if object.motionRole == .pathDriven, let path = object.pathDrive { target = path.points[object.pathIndex] }
            else { continue }
            let delta = target - object.position
            // Normale wskazują od przeszkody do sterowanego obiektu.
            let blocker = contacts[id]?.first { delta.x * $0.normal.x + delta.y * $0.normal.y < -0.0001 }
            if object.motionRole == .pathDriven, blocker != nil, length(object.position - object.previousPosition) < 0.0001 {
                object.pathStopped = true; object.pathBlocker = blocker; object.velocity = .zero; object.angularVelocity = 0
                state.objects[id] = object
            }
            let pathActive = object.motionRole == .pathDriven
            result.append(DriveFeedback(objectID: id, playerDriveID: object.playerDriveID, target: target,
                achievedPoint: object.position, blockingContact: blocker ?? (pathActive ? object.pathBlocker : nil),
                isStopped: pathActive && object.pathStopped))
        }
        return result
    }

    private static func fieldForce(_ field: ForceFieldDescriptor, source: RuntimeObject, point: WorldPoint) -> WorldPoint {
        let delta = point - source.position, c = cos(source.rotation), s = sin(source.rotation)
        let local = WorldPoint(c * delta.x + s * delta.y, -s * delta.x + c * delta.y)
        let distance = length(local), radius: Float
        switch field.geometry.shape {
        case .circle(let r): guard distance <= r else { return .zero }; radius = r
        case .polygon(let geometry):
            let vertices = geometry.vertices
            var inside = false
            for i in vertices.indices {
                let a = vertices[i], b = vertices[(i+1) % vertices.count]
                if (a.y > local.y) != (b.y > local.y), local.x < (b.x-a.x) * (local.y-a.y) / (b.y-a.y) + a.x { inside.toggle() }
            }
            guard inside else { return .zero }
            radius = vertices.map(length).max() ?? 1
        }
        switch field.field {
        case .directional(let force): return WorldPoint(c * force.x - s * force.y, s * force.x + c * force.y)
        case .radial(let strength, let falloff), .vortex(let strength, let falloff):
            guard distance > 0 else { return .zero }
            let scale = strength * (falloff == 0 ? 1 : pow(max(0, 1 - distance / radius), falloff)) / distance
            if case .vortex = field.field { return WorldPoint(-delta.y, delta.x) * scale }
            return delta * scale
        }
    }

    private static func advanceTransitions(_ state: inout RuntimeState, duration: Double) throws {
        // Wartości wszystkich przejść są próbkowane z tego samego początku kroku.
        for (target, transition) in state.transitions {
            let start: TransitionValue
            switch target {
            case .globalForce: start = .vector(state.globalForce)
            case .bubbleRadius(let id): guard let object = state.objects[id] else { continue }; start = .scalar(object.targetRadius)
            case .physicsMaterial(let id, let parameter):
                guard let material = state.physicsMaterials[id] else { continue }
                switch parameter {
                case .deformability: start = .scalar(material.deformability)
                case .damping: start = .scalar(material.damping)
                case .friction: start = .scalar(material.friction)
                case .restitution: start = .scalar(material.restitution)
                }
            default: continue // Kanały prezentacji należą do warstwy prezentacji.
            }
            var progress = state.transitionProgress[target] ?? PhysicalTransitionProgress(initial: start, elapsed: 0)
            progress.elapsed += duration
            let fraction = transition.duration == 0 ? Float(1) : Float(min(1, progress.elapsed / transition.duration))
            let t = curve(transition.curve, fraction)
            let value: TransitionValue
            switch (progress.initial, transition.value) {
            case (.scalar(let from), .scalar(let to)): value = .scalar(from * (1-t) + to * t)
            case (.vector(let from), .vector(let to)): value = .vector(from * (1-t) + to * t)
            default: throw TransactionRejectionReason.incompatibleTransitionValue
            }
            switch (target, value) {
            case (.globalForce, .vector(let force)): state.globalForce = force
            case (.bubbleRadius(let id), .scalar(let radius)): state.objects[id]?.targetRadius = radius
            case (.physicsMaterial(let id, let parameter), .scalar(let scalar)):
                if let m = state.physicsMaterials[id] {
                    state.physicsMaterials[id] = try PhysicsMaterial(kind: m.kind,
                        deformability: parameter == .deformability ? scalar : m.deformability,
                        damping: parameter == .damping ? scalar : m.damping,
                        friction: parameter == .friction ? scalar : m.friction,
                        restitution: parameter == .restitution ? scalar : m.restitution)
                }
            default: break
            }
            if fraction == 1 { state.transitions.removeValue(forKey: target); state.transitionProgress.removeValue(forKey: target) }
            else { state.transitionProgress[target] = progress }
        }
    }

    private static func curve(_ curve: TransitionCurve, _ t: Float) -> Float {
        switch curve {
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1-t) * (1-t)
        case .easeInOut: return t * t * (3 - 2*t)
        case .cubicBezier(let x1, let y1, let x2, let y2):
            func bezier(_ u: Float, _ a: Float, _ b: Float) -> Float {
                let v = 1-u; return 3*v*v*u*a + 3*v*u*u*b + u*u*u
            }
            var low: Float = 0, high: Float = 1
            for _ in 0..<24 { let middle = (low+high)/2; if bezier(middle, x1, x2) < t { low = middle } else { high = middle } }
            return t == 1 ? 1 : bezier((low+high)/2, y1, y2)
        }
    }
}
