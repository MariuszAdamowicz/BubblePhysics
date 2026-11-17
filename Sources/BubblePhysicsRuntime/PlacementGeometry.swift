import BubblePhysicsModel
import BubblePhysicsNativeMetal
import simd

/// Geometria punktu na CPU: kształty brył sztywnych i test, czy punkt leży w ich wnętrzu.
/// Wspólna dla `QueryIndex` (zapytania na opublikowanym stanie) i walidacji punktu w stagerze transakcji.
enum PlacementGeometry {
    enum Shape {
        case circle(center: WorldPoint, radius: Float)
        case capsule(a: WorldPoint, b: WorldPoint, radius: Float)
        case polygon([WorldPoint])
    }

    /// Najmniejsza odległość środków dwóch baniek, poniżej której środki uchodzą za wspólny (CD-D-7): względna do
    /// mniejszego promienia, ale nie mniejsza niż tolerancja położenia solvera `positionTolerance` (ze steppera), żeby
    /// punkty różne o 1 ULP (których naprawa nie rozsunie stabilnie) też były odrzucane.
    static func coincidentCenterTolerance(radius: Float, otherRadius: Float, positionTolerance: Float) -> Float {
        max(1e-4 * min(radius, otherRadius), positionTolerance)
    }
    /// Tolerancja położenia dla steppera, który jej nie podaje (`CompleteStepper`), i domyślna w wywołaniach stagera:
    /// ta sama co w solverze (`NativePublicWorld.positionTolerance`).
    package static let defaultPositionTolerance: Float = NativePublicWorld.positionTolerance

    /// Bryła sztywna z kształtem już w świecie, do wielu testów punktu w jednym stanie.
    struct RigidBody {
        let id: ObjectID
        let shape: Shape
        let filter: CollisionFilter
    }

    /// Kształty w świecie wszystkich brył sztywnych stanu. Scalenie i podział budują je raz na operację, bo wyszukiwanie
    /// kandydatów woła `issue` wiele razy przy niezmienionych bryłach.
    static func rigidBodies(in state: RuntimeState) -> [RigidBody] {
        state.objects.compactMap { id, object in
            guard case .rigidBody(let body) = object.descriptor else { return nil }
            return RigidBody(id: id, shape: shape(of: body, at: object), filter: body.filter)
        }
    }

    /// Pierwsza przyczyna, dla której środek bańki o promieniu `radius` nie może stanąć w `point`, w kolejności
    /// region, bryła, wspólny środek; `nil`, gdy punkt jest poprawny. Obiekty z `excluding` są z testu wyłączone, tak jak
    /// obiekty, których filtr kolizji wyklucza się z `filter` bańki: nigdy z nią nie kolidują, więc solver znosi wspólny środek.
    /// Kształt bryły powstaje dopiero dla bryły, która przeszła filtr i wyłączenia, a skan kończy pierwsze trafienie.
    static func issue(at point: WorldPoint, radius: Float, filter: CollisionFilter, in state: RuntimeState,
                      excluding: Set<ObjectID>, positionTolerance: Float = defaultPositionTolerance) -> PlacementIssue? {
        if let issue = regionIssue(at: point, in: state) { return issue }
        for (id, object) in state.objects where !excluding.contains(id) {
            guard case .rigidBody(let body) = object.descriptor, filter.collides(with: body.filter) else { continue }
            if contains(shape(of: body, at: object), point) { return .insideRigidBody }
        }
        return bubbleIssue(at: point, radius: radius, filter: filter, in: state, excluding: excluding,
                           positionTolerance: positionTolerance)
    }

    /// `issue` z bryłami policzonymi wcześniej przez `rigidBodies(in:)` dla tego samego stanu brył; bańki są skanowane ze `state`.
    static func issue(at point: WorldPoint, radius: Float, filter: CollisionFilter, in state: RuntimeState,
                      excluding: Set<ObjectID>, rigidBodies: [RigidBody], positionTolerance: Float) -> PlacementIssue? {
        if let issue = regionIssue(at: point, in: state) { return issue }
        for body in rigidBodies where !excluding.contains(body.id) {
            if filter.collides(with: body.filter), contains(body.shape, point) { return .insideRigidBody }
        }
        return bubbleIssue(at: point, radius: radius, filter: filter, in: state, excluding: excluding,
                           positionTolerance: positionTolerance)
    }

    /// Region obowiązuje niezależnie od `regionExitPolicy`: `.wrap` przenosi bańkę, która wyszła w kroku,
    /// a nie dopuszcza postawienia jej poza regionem.
    private static func regionIssue(at point: WorldPoint, in state: RuntimeState) -> PlacementIssue? {
        state.configuration.simulationRegion.contains(point) ? nil : .outsideRegion
    }

    /// Wspólny środek z bańką stanu, która koliduje z `filter` i nie jest wyłączona.
    private static func bubbleIssue(at point: WorldPoint, radius: Float, filter: CollisionFilter, in state: RuntimeState,
                                    excluding: Set<ObjectID>, positionTolerance: Float) -> PlacementIssue? {
        for (id, object) in state.objects where !excluding.contains(id) {
            guard case .bubble(let other) = object.descriptor, filter.collides(with: other.filter) else { continue }
            if simd_length(point - object.position)
                < coincidentCenterTolerance(radius: radius, otherRadius: object.targetRadius,
                                            positionTolerance: positionTolerance) {
                return .coincidentCenter
            }
        }
        return nil
    }

    /// Kształt bryły sztywnej w świecie, z jej położenia i obrotu w `object`.
    static func shape(of body: RigidBodyDescriptor, at object: RuntimeObject) -> Shape {
        let c = cos(object.rotation), s = sin(object.rotation)
        func world(_ point: WorldPoint) -> WorldPoint {
            WorldPoint(object.position.x + point.x * c - point.y * s, object.position.y + point.x * s + point.y * c)
        }
        switch body.shape {
        case .polygon(let geometry): return .polygon(geometry.vertices.map(world))
        case .circle(let radius): return .circle(center: object.position, radius: radius)
        case .capsule(let halfLength, let radius):
            return .capsule(a: world([-halfLength, 0]), b: world([halfLength, 0]), radius: radius)
        }
    }

    static func distanceToSegment(_ p: WorldPoint, _ a: WorldPoint, _ b: WorldPoint) -> Float {
        let edge = b - a
        let squared = simd_dot(edge, edge)
        let t = squared > 0 ? max(0, min(1, simd_dot(p - a, edge) / squared)) : 0
        return simd_length(p - (a + edge * t))
    }

    static func contains(_ shape: Shape, _ point: WorldPoint) -> Bool {
        switch shape {
        case .circle(let center, let radius):
            return simd_length_squared(point - center) <= radius * radius
        case .capsule(let a, let b, let radius):
            return distanceToSegment(point, a, b) <= radius
        case .polygon(let vertices):
            return polygonContains(vertices, point)
        }
    }

    /// Parzystość przecięć; punkt na krawędzi liczy się jak wnętrze tylko wtedy, gdy parzystość tak wyjdzie.
    static func polygonContains(_ vertices: [WorldPoint], _ p: WorldPoint) -> Bool {
        var inside = false
        var j = vertices.count - 1
        for i in vertices.indices {
            let a = vertices[i], b = vertices[j]
            if (a.y > p.y) != (b.y > p.y), p.x <= (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
}
