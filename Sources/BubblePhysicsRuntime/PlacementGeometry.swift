import BubblePhysicsModel
import simd

/// Geometria punktu na CPU: kształty brył sztywnych i test, czy punkt leży w ich wnętrzu.
/// Wspólna dla `QueryIndex` (zapytania na opublikowanym stanie) i walidacji punktu w stagerze transakcji.
enum PlacementGeometry {
    enum Shape {
        case circle(center: WorldPoint, radius: Float)
        case capsule(a: WorldPoint, b: WorldPoint, radius: Float)
        case polygon([WorldPoint])
    }

    /// Najmniejsza odległość środków dwóch baniek, poniżej której środki uchodzą za wspólny (CD-D-7, CD-D-8): względna do
    /// mniejszego promienia, ale nie mniejsza niż stała tolerancja położenia `positionTolerance`, żeby punkty różne o 1 ULP
    /// (których nie da się rozsunąć stabilnie) też były odrzucane.
    static func coincidentCenterTolerance(radius: Float, otherRadius: Float) -> Float {
        max(1e-4 * min(radius, otherRadius), positionTolerance)
    }
    /// Stała tolerancja położenia dla walidacji rozmieszczenia (G7-AC2): dawna wartość domyślna solvera, który jej już
    /// nie podaje, więc stager nie bierze jej ze steppera.
    static let positionTolerance: Float = 1e-4

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
                      excluding: Set<ObjectID>) -> PlacementIssue? {
        if let issue = regionIssue(at: point, in: state) { return issue }
        for (id, object) in state.objects where !excluding.contains(id) {
            guard case .rigidBody(let body) = object.descriptor, filter.collides(with: body.filter) else { continue }
            if containsIncludingBoundary(shape(of: body, at: object), point) { return .insideRigidBody }
        }
        return bubbleIssue(at: point, radius: radius, filter: filter, in: state, excluding: excluding)
    }

    /// `issue` z bryłami policzonymi wcześniej przez `rigidBodies(in:)` dla tego samego stanu brył; bańki są skanowane ze `state`.
    static func issue(at point: WorldPoint, radius: Float, filter: CollisionFilter, in state: RuntimeState,
                      excluding: Set<ObjectID>, rigidBodies: [RigidBody]) -> PlacementIssue? {
        if let issue = regionIssue(at: point, in: state) { return issue }
        for body in rigidBodies where !excluding.contains(body.id) {
            if filter.collides(with: body.filter), containsIncludingBoundary(body.shape, point) { return .insideRigidBody }
        }
        return bubbleIssue(at: point, radius: radius, filter: filter, in: state, excluding: excluding)
    }

    /// Najmniejsze ID bańki stanu, której środek leży w bryle `body` (wstawionej albo zamienionej, `object` to jej obiekt w stanie)
    /// i która koliduje z nią według filtrów; `nil`, gdy żadnej (G7-AC1). Obiekty z `excluding` (zastępowany obiekt) są pominięte.
    /// Region i wspólny środek dotyczą bańki, więc tu ich nie ma.
    static func bubbleInside(_ body: RigidBodyDescriptor, at object: RuntimeObject, in state: RuntimeState,
                             excluding: Set<ObjectID> = []) -> ObjectID? {
        let shape = shape(of: body, at: object)
        var found: ObjectID?
        for (id, other) in state.objects where !excluding.contains(id) {
            guard case .bubble(let bubble) = other.descriptor, bubble.filter.collides(with: body.filter),
                  containsIncludingBoundary(shape, other.position) else { continue }
            if found.map({ id.rawValue < $0.rawValue }) ?? true { found = id }
        }
        return found
    }

    /// Region obowiązuje niezależnie od `regionExitPolicy`: `.wrap` przenosi bańkę, która wyszła w kroku,
    /// a nie dopuszcza postawienia jej poza regionem.
    private static func regionIssue(at point: WorldPoint, in state: RuntimeState) -> PlacementIssue? {
        state.configuration.simulationRegion.contains(point) ? nil : .outsideRegion
    }

    /// Wspólny środek z bańką stanu, która koliduje z `filter` i nie jest wyłączona.
    private static func bubbleIssue(at point: WorldPoint, radius: Float, filter: CollisionFilter, in state: RuntimeState,
                                    excluding: Set<ObjectID>) -> PlacementIssue? {
        for (id, object) in state.objects where !excluding.contains(id) {
            guard case .bubble(let other) = object.descriptor, filter.collides(with: other.filter) else { continue }
            if simd_length(point - object.position)
                < coincidentCenterTolerance(radius: radius, otherRadius: object.targetRadius) {
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

    /// `contains` z brzegiem liczonym jako wnętrze (G7-AC1). Koło i kapsuła mają już brzeg w środku (`<=`); wielokąt dostaje
    /// dokładny test punktu na krawędzi, bo parzystość przecięć liczyła do wnętrza tylko prawą i górną część brzegu.
    static func containsIncludingBoundary(_ shape: Shape, _ point: WorldPoint) -> Bool {
        if case .polygon(let vertices) = shape, onBoundary(vertices, point) { return true }
        return contains(shape, point)
    }

    /// Punkt leży dokładnie na krawędzi lub w wierzchołku wielokąta (iloczyn wektorowy równy zeru i punkt w obwiedni odcinka).
    private static func onBoundary(_ vertices: [WorldPoint], _ p: WorldPoint) -> Bool {
        var j = vertices.count - 1
        for i in vertices.indices {
            let a = vertices[i], b = vertices[j]
            j = i
            let cross = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
            if cross == 0, p.x >= min(a.x, b.x), p.x <= max(a.x, b.x), p.y >= min(a.y, b.y), p.y <= max(a.y, b.y) { return true }
        }
        return false
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
