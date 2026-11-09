import Foundation

public enum ModelValidationError: Error, Equatable, Sendable {
    case nonFiniteValue(String)
    case nonPositiveValue(String)
    case valueOutOfRange(String)
    case invalidRectangle
    case polygonHolesUnsupported
    case insufficientPolygonVertices
    case degeneratePolygon
    case selfIntersectingPolygon
    case staticGeometryOutsideSimulationRegion
}

/// Skończony prostokąt osiowy o dodatniej szerokości i wysokości.
public struct WorldRectangle: Equatable, Sendable {
    public let min: WorldPoint
    public let max: WorldPoint

    public init(min: WorldPoint, max: WorldPoint) throws {
        try requireFinite(min, "rectangle.min")
        try requireFinite(max, "rectangle.max")
        guard min.x < max.x, min.y < max.y else { throw ModelValidationError.invalidRectangle }
        self.min = min
        self.max = max
    }

    /// Dla wartości, które pochodzą z solvera i są już sprawdzone (skończone, min ≤ max); bez walidacji i bez rzucania.
    package init(uncheckedMin min: WorldPoint, max: WorldPoint) {
        self.min = min
        self.max = max
    }

    public func contains(_ point: WorldPoint) -> Bool {
        point.x >= min.x && point.x <= max.x && point.y >= min.y && point.y <= max.y
    }
}

public struct WorldConfiguration: Equatable, Sendable {
    /// Obszar pojemności obliczeniowej, nigdy fizyczna ściana.
    public let simulationRegion: WorldRectangle
    public let fixedTimeStep: TimeInterval
    public let eventBufferCapacity: Int
    public let globalForce: WorldPoint
    /// Górny limit zaległego czasu (backlogu) w sekundach; nadmiar jest odrzucany i raportowany w diagnostyce.
    /// Limit krótszy niż krok symulacji działa jak jeden krok, więc nie blokuje symulacji.
    public let maximumBacklog: TimeInterval
    /// Gdy włączone (domyślnie), świat pauzuje po przejściu aplikacji w tło i po powrocie odrzuca pierwszy przyrost czasu.
    public let automaticPause: Bool

    public init(simulationRegion: WorldRectangle, fixedTimeStep: TimeInterval = 1.0 / 60.0,
                eventBufferCapacity: Int = 1024, globalForce: WorldPoint = .zero,
                maximumBacklog: TimeInterval = 0.25, automaticPause: Bool = true) throws {
        guard fixedTimeStep.isFinite else { throw ModelValidationError.nonFiniteValue("fixedTimeStep") }
        guard fixedTimeStep > 0 else { throw ModelValidationError.nonPositiveValue("fixedTimeStep") }
        guard maximumBacklog.isFinite else { throw ModelValidationError.nonFiniteValue("maximumBacklog") }
        guard maximumBacklog > 0 else { throw ModelValidationError.nonPositiveValue("maximumBacklog") }
        guard eventBufferCapacity > 0 else { throw ModelValidationError.nonPositiveValue("eventBufferCapacity") }
        try requireFinite(globalForce, "globalForce")
        self.simulationRegion = simulationRegion
        self.fixedTimeStep = fixedTimeStep
        self.eventBufferCapacity = eventBufferCapacity
        self.globalForce = globalForce
        self.maximumBacklog = maximumBacklog
        self.automaticPause = automaticPause
    }

    /// Walidacja zależna od świata; stager transakcji musi ją ponowić dla swojego regionu.
    public func validate(_ bubble: BubbleDescriptor) throws {
        guard bubble.motionRole == .static else { return }
        try validateCircle(center: bubble.position, radius: bubble.targetRadius)
    }

    public func validate(_ body: RigidBodyDescriptor) throws {
        guard body.motionRole == .static else { return }
        switch body.shape {
        case .polygon(let geometry): try validatePolygon(geometry, position: body.position, rotation: body.rotation)
        case .circle(let radius): try validateCircle(center: body.position, radius: radius)
        case .capsule(let halfLength, let radius):
            // Kapsuła to odcinek osi powiększony o promień: oba końce z kołem o tym promieniu.
            let axis = WorldPoint(cos(body.rotation), sin(body.rotation)) * halfLength
            try validateCircle(center: body.position + axis, radius: radius)
            try validateCircle(center: body.position - axis, radius: radius)
        }
    }

    /// Pola i sensory w tym modelu mają nieruchomy zasięg.
    public func validate(_ field: ForceFieldDescriptor) throws {
        try validateRange(field.geometry, position: field.position, rotation: field.rotation)
    }

    public func validate(_ sensor: SensorDescriptor) throws {
        try validateRange(sensor.geometry, position: sensor.position, rotation: sensor.rotation)
    }

    private func validateCircle(center: WorldPoint, radius: Float) throws {
        let x = Double(center.x), y = Double(center.y), r = Double(radius)
        guard x - r >= Double(simulationRegion.min.x), x + r <= Double(simulationRegion.max.x),
              y - r >= Double(simulationRegion.min.y), y + r <= Double(simulationRegion.max.y) else {
            throw ModelValidationError.staticGeometryOutsideSimulationRegion
        }
    }

    private func validatePolygon(_ geometry: PolygonGeometry, position: WorldPoint, rotation: Float) throws {
        let cosine = cos(Double(rotation)), sine = sin(Double(rotation))
        for vertex in geometry.vertices {
            let x = Double(position.x) + Double(vertex.x) * cosine - Double(vertex.y) * sine
            let y = Double(position.y) + Double(vertex.x) * sine + Double(vertex.y) * cosine
            guard x >= Double(simulationRegion.min.x), x <= Double(simulationRegion.max.x),
                  y >= Double(simulationRegion.min.y), y <= Double(simulationRegion.max.y) else {
                throw ModelValidationError.staticGeometryOutsideSimulationRegion
            }
        }
    }

    private func validateRange(_ geometry: RangeGeometry, position: WorldPoint, rotation: Float) throws {
        switch geometry.shape {
        case .circle(let radius): try validateCircle(center: position, radius: radius)
        case .polygon(let polygon): try validatePolygon(polygon, position: position, rotation: rotation)
        }
    }
}

package func requireFinite(_ value: Float, _ name: String) throws {
    guard value.isFinite else { throw ModelValidationError.nonFiniteValue(name) }
}

package func requireFinite(_ value: WorldPoint, _ name: String) throws {
    guard value.x.isFinite, value.y.isFinite else { throw ModelValidationError.nonFiniteValue(name) }
}

package func requirePositive(_ value: Float, _ name: String) throws {
    try requireFinite(value, name)
    guard value > 0 else { throw ModelValidationError.nonPositiveValue(name) }
}

package func requireNonnegative(_ value: Float, _ name: String) throws {
    try requireFinite(value, name)
    guard value >= 0 else { throw ModelValidationError.valueOutOfRange(name) }
}
