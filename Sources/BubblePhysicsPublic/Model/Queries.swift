/// Wynik raycastu: pierwsze trafienie na odcinku od początku do końca.
public struct RaycastHit: Equatable, Sendable {
    public let objectID: ObjectID
    /// Punkt trafienia w świecie.
    public let point: WorldPoint
    /// Znormalizowana normalna powierzchni w punkcie trafienia, skierowana na zewnątrz obiektu.
    /// Gdy odcinek zaczyna się wewnątrz obiektu, normalna to odwrócony kierunek odcinka (albo zero dla odcinka zerowej długości).
    public let normal: WorldPoint
    /// Ułamek odcinka od początku (0) do końca (1), w którym leży punkt trafienia.
    public let fraction: Float

    package init(objectID: ObjectID, point: WorldPoint, normal: WorldPoint, fraction: Float) {
        self.objectID = objectID; self.point = point; self.normal = normal; self.fraction = fraction
    }
}
