import BubblePhysicsModel

/// Zapytania przestrzenne na opublikowanym stanie (zaślepka do zadania 39).
package struct QueryIndex {
    package init(state: RuntimeState) {}
    package func objects(at point: WorldPoint, filter: CollisionFilter? = nil) -> [ObjectID] { [] }
    package func objects(in rectangle: WorldRectangle, filter: CollisionFilter? = nil) -> [ObjectID] { [] }
    package func objects(inCircle center: WorldPoint, radius: Float, filter: CollisionFilter? = nil) -> [ObjectID] { [] }
    package func raycast(from start: WorldPoint, to end: WorldPoint, filter: CollisionFilter? = nil) -> RaycastHit? { nil }
}
