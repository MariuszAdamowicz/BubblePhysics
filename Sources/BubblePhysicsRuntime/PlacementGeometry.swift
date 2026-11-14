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
    /// mniejszego promienia, ale nie mniejsza niż tolerancja położenia solvera, żeby punkty różne o 1 ULP
    /// (których naprawa nie rozsunie stabilnie) też były odrzucane.
    static func coincidentCenterTolerance(radius: Float, otherRadius: Float) -> Float {
        max(1e-4 * min(radius, otherRadius), positionTolerance)
    }
    /// Tolerancja położenia solvera. Stager nie widzi konfiguracji solvera, a `NativePublicWorld` buduje ją z samego
    /// `timeStep` i tłumienia (`NativePublicWorld.swift:217`), więc rzeczywista wartość świata to domyślne
    /// `NativeSolverConfiguration.positionTolerance`; odczyt z domyślnej konfiguracji trzyma obie strony zgodne.
    private static let positionTolerance = NativeSolverConfiguration().positionTolerance

    /// Pierwsza przyczyna, dla której środek bańki o promieniu `radius` nie może stanąć w `point`, w kolejności
    /// region, bryła, wspólny środek; `nil`, gdy punkt jest poprawny. Obiekty z `excluding` są z testu wyłączone.
    static func issue(at point: WorldPoint, radius: Float, in state: RuntimeState,
                      excluding: Set<ObjectID>) -> PlacementIssue? {
        // Region obowiązuje niezależnie od `regionExitPolicy`: `.wrap` przenosi bańkę, która wyszła w kroku,
        // a nie dopuszcza postawienia jej poza regionem.
        guard state.configuration.simulationRegion.contains(point) else { return .outsideRegion }
        for (id, object) in state.objects where !excluding.contains(id) {
            if case .rigidBody(let body) = object.descriptor, contains(shape(of: body, at: object), point) {
                return .insideRigidBody
            }
        }
        for (id, object) in state.objects where !excluding.contains(id) {
            guard case .bubble = object.descriptor else { continue }
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
