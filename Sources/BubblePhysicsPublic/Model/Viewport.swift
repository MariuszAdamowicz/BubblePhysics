/// Kamera osiowa. Rozmiar oznacza widoczny obszar świata; mniejszy rozmiar daje większy zoom.
public struct Viewport: Equatable, Sendable {
    public let center: WorldPoint
    public let size: WorldPoint

    public init(center: WorldPoint, size: WorldPoint) throws {
        try requireFinite(center, "viewport.center")
        try requirePositive(size.x, "viewport.size.x")
        try requirePositive(size.y, "viewport.size.y")
        self.center = center
        self.size = size
    }

    /// Ekran ma początek w lewym górnym rogu i Y w dół. Jednostki ekranu mogą być punktami
    /// albo pikselami, o ile punkt i screenSize używają tych samych jednostek.
    /// Punkty spoza ekranu są ekstrapolowane; viewport nie ogranicza świata fizycznego.
    public func worldPoint(for screenPoint: WorldPoint, in screenSize: WorldPoint) throws -> WorldPoint {
        try validate(screenPoint, screenSize)
        return try result(
            Double(center.x) + (Double(screenPoint.x) / Double(screenSize.x) - 0.5) * Double(size.x),
            Double(center.y) + (0.5 - Double(screenPoint.y) / Double(screenSize.y)) * Double(size.y))
    }

    public func screenPoint(for worldPoint: WorldPoint, in screenSize: WorldPoint) throws -> WorldPoint {
        try validate(worldPoint, screenSize)
        return try result(
            ((Double(worldPoint.x) - Double(center.x)) / Double(size.x) + 0.5) * Double(screenSize.x),
            (0.5 - (Double(worldPoint.y) - Double(center.y)) / Double(size.y)) * Double(screenSize.y))
    }

    private func validate(_ point: WorldPoint, _ screenSize: WorldPoint) throws {
        try requireFinite(point, "viewport.point")
        try requirePositive(screenSize.x, "screenSize.x")
        try requirePositive(screenSize.y, "screenSize.y")
    }

    private func result(_ x: Double, _ y: Double) throws -> WorldPoint {
        let point = WorldPoint(Float(x), Float(y))
        try requireFinite(point, "viewport.result")
        return point
    }
}
