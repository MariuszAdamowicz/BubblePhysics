import BubblePhysicsModel
import simd

/// Zapytania przestrzenne na opublikowanym stanie, na CPU, bez odczytu konturów z GPU.
/// Bryły są sprawdzane dokładnie (wielokąt, koło, kapsuła), a bańka jako koło o efektywnym promieniu.
/// Czujniki i pola sił nie biorą udziału. Wyniki zbiorowe idą rosnąco po `ObjectID`.
///
/// Filtr zapytania działa jak filtr obiektu: wynik to obiekty, z którymi taki obiekt by kolidował
/// (`CollisionFilter.collides(with:)`); `nil` nie zawęża niczego.
///
/// Indeks to siatka jednorodna po prostokątach otaczających. Powstaje z jednego `RuntimeState`, więc `BubbleWorld` buduje
/// go najwyżej raz na publikację, przy pierwszym zapytaniu. Obiekty obejmujące bardzo wiele komórek (duże ściany)
/// leżą na osobnej liście i są sprawdzane przy każdym zapytaniu.
package struct QueryIndex {
    private enum Shape {
        case circle(center: WorldPoint, radius: Float)
        case capsule(a: WorldPoint, b: WorldPoint, radius: Float)
        case polygon([WorldPoint])
    }

    private struct Entry {
        let id: ObjectID
        let filter: CollisionFilter
        let shape: Shape
        let low: WorldPoint
        let high: WorldPoint
    }

    private struct Cell: Hashable { let x: Int, y: Int }

    /// Posortowane rosnąco po `ObjectID`, więc rosnący indeks to rosnący identyfikator.
    private let entries: [Entry]
    private var cells: [Cell: [Int32]] = [:]
    private var large: [Int32] = []
    private let cellSize: Float
    /// Zapytanie obejmujące więcej komórek niż ten próg przegląda wszystkie wpisy.
    private static let scanLimit = 4096
    /// Obiekt obejmujący więcej komórek w jednej osi trafia na listę dużych.
    private static let largeSpan = 16

    package init(state: RuntimeState) {
        var built: [Entry] = []
        built.reserveCapacity(state.objects.count)
        for (id, object) in state.objects {
            switch object.descriptor {
            case .bubble(let bubble):
                let radius = max(object.effectiveRadius, 0)
                built.append(Self.entry(id, bubble.filter, .circle(center: object.position, radius: radius)))
            case .rigidBody(let body):
                let c = cos(object.rotation), s = sin(object.rotation)
                func world(_ point: WorldPoint) -> WorldPoint {
                    WorldPoint(object.position.x + point.x * c - point.y * s, object.position.y + point.x * s + point.y * c)
                }
                switch body.shape {
                case .polygon(let geometry):
                    built.append(Self.entry(id, body.filter, .polygon(geometry.vertices.map(world))))
                case .circle(let radius):
                    built.append(Self.entry(id, body.filter, .circle(center: object.position, radius: radius)))
                case .capsule(let halfLength, let radius):
                    built.append(Self.entry(id, body.filter,
                        .capsule(a: world([-halfLength, 0]), b: world([halfLength, 0]), radius: radius)))
                }
            case .sensor, .forceField: continue
            }
        }
        built.sort { $0.id.rawValue < $1.id.rawValue }
        entries = built
        let extents = built.map { max($0.high.x - $0.low.x, $0.high.y - $0.low.y) }.sorted()
        let median = extents.isEmpty ? 1 : extents[extents.count / 2]
        cellSize = median.isFinite && median > 1e-3 ? median : 1
        for (index, entry) in built.enumerated() {
            let (low, high) = cellRange(entry.low, entry.high)
            if high.x - low.x >= Self.largeSpan || high.y - low.y >= Self.largeSpan {
                large.append(Int32(index))
                continue
            }
            for x in low.x...high.x { for y in low.y...high.y { cells[Cell(x: x, y: y), default: []].append(Int32(index)) } }
        }
    }

    private static func entry(_ id: ObjectID, _ filter: CollisionFilter, _ shape: Shape) -> Entry {
        let low: WorldPoint, high: WorldPoint
        switch shape {
        case .circle(let center, let radius):
            low = center - WorldPoint(repeating: radius); high = center + WorldPoint(repeating: radius)
        case .capsule(let a, let b, let radius):
            low = pointwiseMin(a, b) - WorldPoint(repeating: radius); high = pointwiseMax(a, b) + WorldPoint(repeating: radius)
        case .polygon(let vertices):
            low = vertices.dropFirst().reduce(vertices[0]) { pointwiseMin($0, $1) }
            high = vertices.dropFirst().reduce(vertices[0]) { pointwiseMax($0, $1) }
        }
        return Entry(id: id, filter: filter, shape: shape, low: low, high: high)
    }

    // MARK: siatka

    private func cell(_ value: Float) -> Int {
        let scaled = (value / cellSize).rounded(.down)
        return scaled.isFinite ? Int(max(-1_000_000, min(1_000_000, scaled))) : 0
    }

    private func cellRange(_ low: WorldPoint, _ high: WorldPoint) -> (low: Cell, high: Cell) {
        (Cell(x: cell(low.x), y: cell(low.y)), Cell(x: cell(high.x), y: cell(high.y)))
    }

    /// Indeksy wpisów, których prostokąt może przecinać prostokąt zapytania, rosnąco i bez powtórzeń.
    private func candidates(low: WorldPoint, high: WorldPoint) -> [Int32] {
        let range = cellRange(low, high)
        let (width, height) = (range.high.x - range.low.x + 1, range.high.y - range.low.y + 1)
        guard width * height <= Self.scanLimit else { return Array(entries.indices.map { Int32($0) }) }
        var found = large
        for x in range.low.x...range.high.x {
            for y in range.low.y...range.high.y { if let list = cells[Cell(x: x, y: y)] { found += list } }
        }
        found.sort()
        var unique: [Int32] = []
        unique.reserveCapacity(found.count)
        for index in found where unique.last != index { unique.append(index) }
        return unique
    }

    private func accepts(_ entry: Entry, _ filter: CollisionFilter?) -> Bool {
        filter.map { $0.collides(with: entry.filter) } ?? true
    }

    // MARK: zapytania zbiorowe

    package func objects(at point: WorldPoint, filter: CollisionFilter? = nil) -> [ObjectID] {
        guard point.x.isFinite, point.y.isFinite else { return [] }
        return candidates(low: point, high: point).compactMap { index in
            let entry = entries[Int(index)]
            guard accepts(entry, filter), Self.contains(entry.shape, point) else { return nil }
            return entry.id
        }
    }

    package func objects(in rectangle: WorldRectangle, filter: CollisionFilter? = nil) -> [ObjectID] {
        candidates(low: rectangle.min, high: rectangle.max).compactMap { index in
            let entry = entries[Int(index)]
            guard accepts(entry, filter), Self.intersects(entry.shape, low: rectangle.min, high: rectangle.max)
            else { return nil }
            return entry.id
        }
    }

    package func objects(inCircle center: WorldPoint, radius: Float, filter: CollisionFilter? = nil) -> [ObjectID] {
        guard center.x.isFinite, center.y.isFinite, radius.isFinite, radius >= 0 else { return [] }
        let extent = WorldPoint(repeating: radius)
        return candidates(low: center - extent, high: center + extent).compactMap { index in
            let entry = entries[Int(index)]
            guard accepts(entry, filter), Self.intersects(entry.shape, center: center, radius: radius) else { return nil }
            return entry.id
        }
    }

    // MARK: raycast

    /// Pierwsze trafienie na odcinku od `start` do `end`. Odcinek zaczynający się we wnętrzu obiektu trafia go z ułamkiem 0.
    /// Przy remisie wygrywa mniejszy `ObjectID`.
    package func raycast(from start: WorldPoint, to end: WorldPoint, filter: CollisionFilter? = nil) -> RaycastHit? {
        guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { return nil }
        let direction = end - start
        var best: (index: Int, fraction: Float, normal: WorldPoint)?
        for index in candidates(low: pointwiseMin(start, end), high: pointwiseMax(start, end)) {
            let entry = entries[Int(index)]
            guard accepts(entry, filter), Self.segmentMayTouch(start, direction, entry.low, entry.high) else { continue }
            let hit: (fraction: Float, normal: WorldPoint)?
            if Self.contains(entry.shape, start) {
                let length = simd_length(direction)
                hit = (0, length > 0 ? -direction / length : .zero)
            } else {
                hit = Self.raycast(entry.shape, start, direction)
            }
            if let hit {
                if let current = best, hit.fraction >= current.fraction { continue }
                best = (Int(index), hit.fraction, hit.normal)
            }
        }
        guard let best else { return nil }
        return RaycastHit(objectID: entries[best.index].id, point: start + direction * best.fraction,
                          normal: best.normal, fraction: best.fraction)
    }

    /// Test płyt odcinka z prostokątem otaczającym.
    private static func segmentMayTouch(_ start: WorldPoint, _ direction: WorldPoint,
                                        _ low: WorldPoint, _ high: WorldPoint) -> Bool {
        var near: Float = 0, far: Float = 1
        for axis in 0..<2 {
            if direction[axis] == 0 {
                if start[axis] < low[axis] || start[axis] > high[axis] { return false }
            } else {
                var t1 = (low[axis] - start[axis]) / direction[axis], t2 = (high[axis] - start[axis]) / direction[axis]
                if t1 > t2 { swap(&t1, &t2) }
                near = max(near, t1); far = min(far, t2)
                if near > far { return false }
            }
        }
        return true
    }

    private static func raycast(_ shape: Shape, _ start: WorldPoint, _ direction: WorldPoint)
        -> (fraction: Float, normal: WorldPoint)? {
        switch shape {
        case .circle(let center, let radius):
            return rayCircle(start, direction, center, radius)
        case .capsule(let a, let b, let radius):
            var best: (fraction: Float, normal: WorldPoint)?
            func consider(_ hit: (fraction: Float, normal: WorldPoint)?) {
                if let hit, hit.fraction < (best?.fraction ?? .infinity) { best = hit }
            }
            consider(rayCircle(start, direction, a, radius))
            consider(rayCircle(start, direction, b, radius))
            let axis = b - a
            let length = simd_length(axis)
            guard length > 0 else { return best }
            let side = WorldPoint(-axis.y, axis.x) / length * radius
            for sign: Float in [1, -1] {
                consider(raySegment(start, direction, a + side * sign, b + side * sign, outward: side * sign))
            }
            return best
        case .polygon(let vertices):
            var best: (fraction: Float, normal: WorldPoint)?
            for i in vertices.indices {
                let a = vertices[i], b = vertices[(i + 1) % vertices.count]
                if let hit = raySegment(start, direction, a, b, outward: nil), hit.fraction < (best?.fraction ?? .infinity) {
                    best = hit
                }
            }
            return best
        }
    }

    /// Wejście promienia w koło z zewnątrz (`start` leży poza kołem).
    private static func rayCircle(_ start: WorldPoint, _ direction: WorldPoint, _ center: WorldPoint,
                                  _ radius: Float) -> (fraction: Float, normal: WorldPoint)? {
        let offset = start - center
        let a = simd_dot(direction, direction)
        guard a > 0 else { return nil }
        let b = simd_dot(offset, direction)
        let c = simd_dot(offset, offset) - radius * radius
        let discriminant = b * b - a * c
        guard discriminant >= 0 else { return nil }
        let t = (-b - discriminant.squareRoot()) / a
        guard t >= 0, t <= 1 else { return nil }
        let point = offset + direction * t
        let length = simd_length(point)
        return (t, length > 0 ? point / length : .zero)
    }

    /// Przecięcie promienia z odcinkiem. Normalna to normalna odcinka zwrócona przeciw promieniowi
    /// (albo `outward`, gdy znana z góry); odcinek równoległy do promienia nic nie trafia.
    private static func raySegment(_ start: WorldPoint, _ direction: WorldPoint, _ a: WorldPoint, _ b: WorldPoint,
                                   outward: WorldPoint?) -> (fraction: Float, normal: WorldPoint)? {
        let edge = b - a
        let denominator = direction.x * edge.y - direction.y * edge.x
        guard denominator != 0 else { return nil }
        let delta = a - start
        let t = (delta.x * edge.y - delta.y * edge.x) / denominator
        let u = (delta.x * direction.y - delta.y * direction.x) / denominator
        guard t >= 0, t <= 1, u >= 0, u <= 1 else { return nil }
        var normal = outward ?? WorldPoint(-edge.y, edge.x)
        let length = simd_length(normal)
        guard length > 0 else { return nil }
        normal /= length
        if outward == nil, simd_dot(normal, direction) > 0 { normal = -normal }
        return (t, normal)
    }

    // MARK: geometria

    private static func distanceToSegment(_ p: WorldPoint, _ a: WorldPoint, _ b: WorldPoint) -> Float {
        let edge = b - a
        let squared = simd_dot(edge, edge)
        let t = squared > 0 ? max(0, min(1, simd_dot(p - a, edge) / squared)) : 0
        return simd_length(p - (a + edge * t))
    }

    private static func contains(_ shape: Shape, _ point: WorldPoint) -> Bool {
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
    private static func polygonContains(_ vertices: [WorldPoint], _ p: WorldPoint) -> Bool {
        var inside = false
        var j = vertices.count - 1
        for i in vertices.indices {
            let a = vertices[i], b = vertices[j]
            if (a.y > p.y) != (b.y > p.y), p.x <= (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }

    private static func rectangleContains(_ low: WorldPoint, _ high: WorldPoint, _ p: WorldPoint) -> Bool {
        p.x >= low.x && p.x <= high.x && p.y >= low.y && p.y <= high.y
    }

    private static func rectangleDistance(_ low: WorldPoint, _ high: WorldPoint, _ p: WorldPoint) -> Float {
        simd_length(p - pointwiseMin(pointwiseMax(p, low), high))
    }

    private static func segmentsIntersect(_ a: WorldPoint, _ b: WorldPoint, _ c: WorldPoint, _ d: WorldPoint) -> Bool {
        func cross(_ p: WorldPoint, _ q: WorldPoint, _ r: WorldPoint) -> Float {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        func onSegment(_ p: WorldPoint, _ q: WorldPoint, _ r: WorldPoint) -> Bool {
            r.x >= min(p.x, q.x) && r.x <= max(p.x, q.x) && r.y >= min(p.y, q.y) && r.y <= max(p.y, q.y)
        }
        let d1 = cross(a, b, c), d2 = cross(a, b, d), d3 = cross(c, d, a), d4 = cross(c, d, b)
        if ((d1 > 0 && d2 < 0) || (d1 < 0 && d2 > 0)) && ((d3 > 0 && d4 < 0) || (d3 < 0 && d4 > 0)) { return true }
        return (d1 == 0 && onSegment(a, b, c)) || (d2 == 0 && onSegment(a, b, d))
            || (d3 == 0 && onSegment(c, d, a)) || (d4 == 0 && onSegment(c, d, b))
    }

    private static func segmentDistance(_ a: WorldPoint, _ b: WorldPoint, _ c: WorldPoint, _ d: WorldPoint) -> Float {
        if segmentsIntersect(a, b, c, d) { return 0 }
        return min(distanceToSegment(a, c, d), distanceToSegment(b, c, d),
                   distanceToSegment(c, a, b), distanceToSegment(d, a, b))
    }

    private static func intersects(_ shape: Shape, low: WorldPoint, high: WorldPoint) -> Bool {
        let corners: [WorldPoint] = [low, [high.x, low.y], high, [low.x, high.y]]
        switch shape {
        case .circle(let center, let radius):
            return rectangleDistance(low, high, center) <= radius
        case .capsule(let a, let b, let radius):
            if rectangleContains(low, high, a) || rectangleContains(low, high, b) { return true }
            for i in corners.indices where segmentDistance(a, b, corners[i], corners[(i + 1) % 4]) <= radius { return true }
            return false
        case .polygon(let vertices):
            if vertices.contains(where: { rectangleContains(low, high, $0) }) { return true }
            if corners.contains(where: { polygonContains(vertices, $0) }) { return true }
            for i in vertices.indices {
                let a = vertices[i], b = vertices[(i + 1) % vertices.count]
                for k in corners.indices where segmentsIntersect(a, b, corners[k], corners[(k + 1) % 4]) { return true }
            }
            return false
        }
    }

    private static func intersects(_ shape: Shape, center: WorldPoint, radius: Float) -> Bool {
        switch shape {
        case .circle(let other, let otherRadius):
            let reach = radius + otherRadius
            return simd_length_squared(center - other) <= reach * reach
        case .capsule(let a, let b, let capsuleRadius):
            return distanceToSegment(center, a, b) <= radius + capsuleRadius
        case .polygon(let vertices):
            if polygonContains(vertices, center) { return true }
            for i in vertices.indices where distanceToSegment(center, vertices[i], vertices[(i + 1) % vertices.count]) <= radius {
                return true
            }
            return false
        }
    }
}
