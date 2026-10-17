import Foundation
import BubblePhysicsModel
import BubblePhysicsNativeMetal

/// Staging masy, pędu i intencji kształtu. Próbowanie i relaksacja konturu należą do GPU.
enum StructuralOperations {
    static func sources(_ object: RuntimeObject) -> [NativeStructuralSource] {
        object.structuralShape?.sources ?? [.init(id: object.descriptor.id, center: object.position, radius: object.collisionRadius)]
    }
    static func mergeCenter(_ objects: [RuntimeObject]) -> WorldPoint {
        var center = SIMD2<Double>.zero, pairs: Double = 0
        for i in objects.indices {
            for j in objects.indices where j > i {
                let a = objects[i], b = objects[j], delta = b.position-a.position
                let distance = hypot(delta.x, delta.y)
                let normal = distance > 0 ? delta/distance : WorldPoint(1,0)
                let point = (a.position + b.position + normal * (a.collisionRadius-b.collisionRadius)) * 0.5
                center += SIMD2(Double(point.x),Double(point.y)); pairs += 1
            }
        }
        return WorldPoint(Float(center.x/pairs),Float(center.y/pairs))
    }
    static func initializeMerge(_ result: inout RuntimeObject, sources inputs: [RuntimeObject]) {
        result.structuralShape = .init(origin: result.position, sources: inputs.flatMap(sources))
        var angularMomentum: Double = 0
        for object in inputs {
            let m = Double(object.mass!), r = Double(object.targetRadius), d = object.position-result.position
            angularMomentum += 0.5*m*r*r*Double(object.angularVelocity)
                + m*(Double(d.x)*Double(object.velocity.y)-Double(d.y)*Double(object.velocity.x))
        }
        result.angularVelocity = Float(angularMomentum/(0.5*Double(result.mass!)*Double(result.targetRadius)*Double(result.targetRadius)))
    }
    static func initializeSplit(_ first: inout RuntimeObject, _ second: inout RuntimeObject,
                                source: RuntimeObject, share: Float) {
        // Cięciwa i centroidy dwóch segmentów koła zachowują udziały pola i środek masy.
        let r = Double(source.collisionRadius), area = Double.pi*r*r
        var low = -r, high = r
        for _ in 0..<48 {
            let x = (low+high)*0.5
            let left = r*r*(asin(x/r)+Double.pi/2)+x*sqrt(max(0,r*r-x*x))
            if left < area*Double(share) { low = x } else { high = x }
        }
        let cut = (low+high)*0.5, moment = 2.0/3 * pow(max(0,r*r-cut*cut),1.5)
        let x1 = -moment/(area*Double(share)), x2 = moment/(area*(1-Double(share)))
        let axis = WorldPoint(cos(source.rotation),sin(source.rotation))
        first.position = source.position + axis*Float(x1)
        second.position = source.position + axis*Float(x2)
        first.previousPosition = first.position; second.previousPosition = second.position
        let ownInertia = 0.5*(Double(first.mass!)*Double(first.targetRadius)*Double(first.targetRadius)
            + Double(second.mass!)*Double(second.targetRadius)*Double(second.targetRadius))
        let inertia = ownInertia + Double(first.mass!)*x1*x1 + Double(second.mass!)*x2*x2
        let omega = Float(0.5*Double(source.mass!)*Double(source.targetRadius)*Double(source.targetRadius)*Double(source.angularVelocity)/inertia)
        let tangent = WorldPoint(-axis.y,axis.x)
        first.velocity = source.velocity+tangent*(Float(x1)*omega)
        second.velocity = source.velocity+tangent*(Float(x2)*omega)
        first.angularVelocity = omega; second.angularVelocity = omega
        let distance = axis.x*source.position.x+axis.y*source.position.y+Float(cut)
        var left = sources(source), right = left
        for i in left.indices { left[i].clips.append(SIMD4(axis.x,axis.y,distance,0)) }
        for i in right.indices { right[i].clips.append(SIMD4(-axis.x,-axis.y,-distance,0)) }
        first.structuralShape = .init(origin: first.position,sources: left)
        second.structuralShape = .init(origin: second.position,sources: right)
    }
}
