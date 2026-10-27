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
    public let arenas: [ArenaPreset]

    public init(simulationRegion: WorldRectangle, fixedTimeStep: TimeInterval = 1.0 / 60.0,
                eventBufferCapacity: Int = 1024, globalForce: WorldPoint = .zero,
                arenas: [ArenaPreset] = []) throws {
        guard fixedTimeStep.isFinite else { throw ModelValidationError.nonFiniteValue("fixedTimeStep") }
        guard fixedTimeStep > 0 else { throw ModelValidationError.nonPositiveValue("fixedTimeStep") }
        guard eventBufferCapacity > 0 else { throw ModelValidationError.nonPositiveValue("eventBufferCapacity") }
        try requireFinite(globalForce, "globalForce")
        guard Set(arenas.map(\.id)).count == arenas.count else {
            throw ModelValidationError.valueOutOfRange("arena.duplicateID")
        }
        for arena in arenas {
            guard simulationRegion.contains(arena.bounds.min), simulationRegion.contains(arena.bounds.max) else {
                throw ModelValidationError.invalidRectangle
            }
        }
        self.simulationRegion = simulationRegion
        self.fixedTimeStep = fixedTimeStep
        self.eventBufferCapacity = eventBufferCapacity
        self.globalForce = globalForce
        self.arenas = arenas
    }

    /// Walidacja zależna od świata; stager transakcji musi ją ponowić dla swojego regionu.
    public func validate(_ bubble: BubbleDescriptor) throws {
        guard bubble.motionRole == .static else { return }
        try validateCircle(center: bubble.position, radius: bubble.targetRadius)
    }

    public func validate(_ polygon: PolygonDescriptor) throws {
        guard polygon.motionRole == .static else { return }
        try validatePolygon(polygon.geometry, position: polygon.position, rotation: polygon.rotation)
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
