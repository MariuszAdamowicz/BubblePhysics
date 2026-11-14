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
    /// Punkty, w których silnik próbuje postawić wynik, gdy punkt styku jest zły (CD-D-6), od najlepszego:
    /// punkty P + t · (S_i − P) dla t = 0,25, 0,5, 0,75 dla każdego źródła w kolejności `sources`, środki źródeł,
    /// potem 8 pierścieni po 16 punktów wokół środka źródła o największej masie (przy równych masach wygrywa
    /// pierwsze w kolejności). Pierścień j ma promień j · r_wyniku / 4. To 3N + N + 128 punktów.
    static func mergeCandidates(contact: WorldPoint, sources: [RuntimeObject], resultRadius: Float) -> [WorldPoint] {
        var points: [WorldPoint] = []
        for source in sources {
            for t: Float in [0.25, 0.5, 0.75] { points.append(contact + (source.position - contact) * t) }
        }
        points += sources.map(\.position)
        var heaviest = sources[0]
        for source in sources.dropFirst() where source.mass! > heaviest.mass! { heaviest = source }
        points += spiral(around: heaviest.position, ringStep: resultRadius / 4)
        return points
    }
    /// 8 pierścieni po 16 punktów o promieniach j · `ringStep`, j = 1…8, od wewnętrznego.
    static func spiral(around center: WorldPoint, ringStep: Float) -> [WorldPoint] {
        var points: [WorldPoint] = []
        for ring in 1...8 {
            for k in 0..<16 {
                let angle = Float(k) * (2 * Float.pi / 16), radius = Float(ring) * ringStep
                points.append(center + WorldPoint(cos(angle), sin(angle)) * radius)
            }
        }
        return points
    }
    /// Punkt wyniku scalenia: punkt styku, jeśli `issue` go przepuszcza, inaczej pierwszy poprawny kandydat;
    /// `nil`, gdy nie ma żadnego. `issue` zwraca przyczynę złego punktu (test bez źródeł scalenia).
    static func resolvedMergeCenter(contact: WorldPoint, sources: [RuntimeObject], resultRadius: Float,
                                    issue: (WorldPoint) -> PlacementIssue?) -> WorldPoint? {
        if issue(contact) == nil { return contact }
        return mergeCandidates(contact: contact, sources: sources, resultRadius: resultRadius)
            .first { issue($0) == nil }
    }
    static func initializeMerge(_ result: inout RuntimeObject, sources inputs: [RuntimeObject]) {
        result.structuralShape = .init(origin: result.position, sources: inputs.flatMap(sources))
        var angularMomentum: Double = 0, sourceMass: Double = 0
        for object in inputs {
            let m = Double(object.mass!), r = Double(object.targetRadius), d = object.position-result.position
            sourceMass += m
            angularMomentum += 0.5*m*r*r*Double(object.angularVelocity)
                + m*(Double(d.x)*Double(object.velocity.y)-Double(d.y)*Double(object.velocity.x))
        }
        // Bezwładność z sumy mas źródeł: nadpisana `result.mass` nie zmienia prędkości kątowej wyniku.
        result.angularVelocity = Float(angularMomentum/(0.5*sourceMass*Double(result.targetRadius)*Double(result.targetRadius)))
    }
    static func initializeSplit(_ first: inout RuntimeObject, _ second: inout RuntimeObject,
                                source: RuntimeObject, shares: (Double, Double)) throws {
        // Cięciwa i centroidy dwóch segmentów koła zachowują udziały pola i środek masy.
        let r = Double(source.collisionRadius), area = Double.pi*r*r
        var low = -r, high = r
        for _ in 0..<48 {
            let x = (low+high)*0.5
            let left = r*r*(asin(x/r)+Double.pi/2)+x*sqrt(max(0,r*r-x*x))
            if left < area*shares.0 { low = x } else { high = x }
        }
        let cut = (low+high)*0.5, moment = 2.0/3 * pow(max(0,r*r-cut*cut),1.5)
        let x1 = -moment/(area*shares.0), x2 = moment/(area*shares.1)
        guard x1.isFinite, x2.isFinite, Float(x1).isFinite, Float(x2).isFinite,
              x1 < x2 else { throw TransactionRejectionReason.invalidStructuralOperation }
        let axis = WorldPoint(cos(source.rotation),sin(source.rotation))
        first.position = source.position + axis*Float(x1)
        second.position = source.position + axis*Float(x2)
        first.previousPosition = first.position; second.previousPosition = second.position
        let ownInertia = 0.5*(Double(first.mass!)*Double(first.targetRadius)*Double(first.targetRadius)
            + Double(second.mass!)*Double(second.targetRadius)*Double(second.targetRadius))
        let inertia = ownInertia + Double(first.mass!)*x1*x1 + Double(second.mass!)*x2*x2
        let omega = Float(0.5*Double(source.mass!)*Double(source.targetRadius)*Double(source.targetRadius)*Double(source.angularVelocity)/inertia)
        guard omega.isFinite else { throw TransactionRejectionReason.invalidStructuralOperation }
        let tangent = WorldPoint(-axis.y,axis.x)
        first.velocity = source.velocity+tangent*(Float(x1)*omega)
        second.velocity = source.velocity+tangent*(Float(x2)*omega)
        guard first.position.x.isFinite, first.position.y.isFinite,
              second.position.x.isFinite, second.position.y.isFinite,
              first.velocity.x.isFinite, first.velocity.y.isFinite,
              second.velocity.x.isFinite, second.velocity.y.isFinite,
              first.position != second.position else {
            throw TransactionRejectionReason.invalidStructuralOperation
        }
        first.angularVelocity = omega; second.angularVelocity = omega
        let distance = axis.x*source.position.x+axis.y*source.position.y+Float(cut)
        var left = sources(source), right = left
        for i in left.indices { left[i].clips.append(SIMD4(axis.x,axis.y,distance,0)) }
        for i in right.indices { right[i].clips.append(SIMD4(-axis.x,-axis.y,-distance,0)) }
        first.structuralShape = .init(origin: first.position,sources: left)
        second.structuralShape = .init(origin: second.position,sources: right)
    }
    /// Punkt części podziału: centroid, jeśli `issue` go przepuszcza, inaczej pierwszy poprawny kandydat; `nil`, gdy
    /// nie ma żadnego. Kandydaci: C + t · (S − C) dla t = 0,25, 0,5, 0,75 (C to centroid, S środek źródła), potem S,
    /// potem 8 pierścieni po 16 punktów wokół S o promieniach j · r_części / 4. To 3 + 1 + 128 = 132 punkty.
    static func resolvedSplitCenter(centroid: WorldPoint, sourceCenter: WorldPoint, partRadius: Float,
                                    issue: (WorldPoint) -> PlacementIssue?) -> WorldPoint? {
        if issue(centroid) == nil { return centroid }
        var candidates = [Float(0.25), 0.5, 0.75].map { centroid + (sourceCenter - centroid) * $0 }
        candidates.append(sourceCenter)
        candidates += spiral(around: sourceCenter, ringStep: partRadius / 4)
        return candidates.first { issue($0) == nil }
    }
    /// Gdy część stoi poza centroidem, środek masy części d_com = (m₁d₁ + m₂d₂) / (m₁ + m₂) odsuwa się od środka źródła
    /// (d_i to przesunięcie części względem źródła). Prędkości liczone od nowa względem d_com zachowują pęd liniowy
    /// i moment pędu źródła: v_i = v_s + ω × (d_i − d_com), a ω wynika z momentu pędu źródła i bezwładności części
    /// liczonej względem d_com. Kształt strukturalny każdej części ma początek w jej końcowym środku.
    static func relocateSplitParts(_ first: inout RuntimeObject, _ second: inout RuntimeObject,
                                   source: RuntimeObject) throws {
        func offset(_ part: RuntimeObject) -> SIMD2<Double> {
            SIMD2(Double(part.position.x) - Double(source.position.x), Double(part.position.y) - Double(source.position.y))
        }
        let m1 = Double(first.mass!), m2 = Double(second.mass!)
        let d1 = offset(first), d2 = offset(second)
        let com = (d1 * m1 + d2 * m2) / (m1 + m2)
        let r1 = d1 - com, r2 = d2 - com
        let ownInertia = 0.5 * (m1 * Double(first.targetRadius) * Double(first.targetRadius)
            + m2 * Double(second.targetRadius) * Double(second.targetRadius))
        let inertia = ownInertia + m1 * (r1.x * r1.x + r1.y * r1.y) + m2 * (r2.x * r2.x + r2.y * r2.y)
        let omega = Float(0.5 * Double(source.mass!) * Double(source.targetRadius) * Double(source.targetRadius)
            * Double(source.angularVelocity) / inertia)
        func velocity(_ r: SIMD2<Double>) -> WorldPoint {
            WorldPoint(source.velocity.x + Float(-r.y) * omega, source.velocity.y + Float(r.x) * omega)
        }
        first.velocity = velocity(r1); second.velocity = velocity(r2)
        guard omega.isFinite, first.velocity.x.isFinite, first.velocity.y.isFinite,
              second.velocity.x.isFinite, second.velocity.y.isFinite else {
            throw TransactionRejectionReason.invalidStructuralOperation
        }
        first.angularVelocity = omega; second.angularVelocity = omega
        first.previousPosition = first.position; second.previousPosition = second.position
        first.structuralShape?.origin = first.position
        second.structuralShape?.origin = second.position
    }
}
