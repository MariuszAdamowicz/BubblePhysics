import simd

/// Krawędzie statycznego wielokąta jako odcinki solvera, które odpychają bańkę tylko od zewnątrz (CD-D-3, CD-D-4).
///
/// Host liczy znak pola wielokąta, więc strona zewnętrzna każdej krawędzi nie zależy od tego, w którą stronę gra podała wierzchołki.
/// Dla każdej krawędzi zapisuje, czy jej końce są ściśle wypukłe, oraz początek krawędzi poprzedniej: obszar wypukłego wierzchołka
/// należy do krawędzi, która się w nim zaczyna, a jego granicę wyznacza rzut środka bańki na krawędź poprzednią. Krawędzie
/// współliniowe w tolerancji `collinearTolerance` są scalane przed budową odcinków, więc każdy pozostały wierzchołek jest ściśle
/// wypukły albo ściśle wklęsły.
package enum NativeStaticPolygonEdges {
    /// Krawędzie sąsiednie e₁, e₂ są scalane, gdy |e₁ × e₂| ≤ tolerancja · |e₁| · |e₂| i e₁ · e₂ > 0.
    package static let collinearTolerance: Double = 1e-5

    /// Odcinki wielokąta o wierzchołkach `points` (zamykająca krawędź jest domyślna), z kolejnymi identyfikatorami od `firstID`.
    /// Wielokąt o zerowym polu (którego solver i tak nie przyjmie) daje zwykłe odcinki bez `polygonEdge`.
    package static func segments(points: [SIMD2<Float>], firstID: Int, ownerID: Int?) -> [NativeSolverSegment] {
        let area = signedArea(points)
        guard points.count >= 3, area != 0 else {
            return points.indices.map { index in
                .fixed(id: firstID + index, a: points[index], b: points[(index + 1) % points.count], ownerID: ownerID)
            }
        }
        let ring = mergingCollinearEdges(points)
        let orientation: Double = area > 0 ? 1 : -1
        let count = ring.count
        return ring.indices.map { index in
            let previous = ring[(index + count - 1) % count], a = ring[index], b = ring[(index + 1) % count]
            let next = ring[(index + 2) % count]
            var segment = NativeSolverSegment.fixed(id: firstID + index, a: a, b: b, ownerID: ownerID)
            segment.polygonEdge = NativeSolverPolygonEdge(
                outwardSign: area > 0 ? -1 : 1,
                convexStart: cross(a - previous, b - a) * orientation > 0,
                convexEnd: cross(b - a, next - b) * orientation > 0,
                previousStart: previous)
            return segment
        }
    }

    private static func cross(_ u: SIMD2<Float>, _ v: SIMD2<Float>) -> Double {
        Double(u.x) * Double(v.y) - Double(u.y) * Double(v.x)
    }

    /// Podwojone pole ze znakiem (dodatnie dla obiegu przeciwnego do ruchu wskazówek zegara), liczone w `Double` względem pierwszego wierzchołka.
    private static func signedArea(_ points: [SIMD2<Float>]) -> Double {
        guard points.count >= 3 else { return 0 }
        var total = 0.0
        for index in 1..<(points.count - 1) { total += cross(points[index] - points[0], points[index + 1] - points[0]) }
        return total
    }

    /// Usuwa wierzchołki, w których krawędź wchodząca i wychodząca są współliniowe w tolerancji i zgodne co do kierunku.
    private static func mergingCollinearEdges(_ points: [SIMD2<Float>]) -> [SIMD2<Float>] {
        var ring = points
        var removed = true
        while removed, ring.count > 3 {
            removed = false
            var index = 0
            while index < ring.count, ring.count > 3 {
                let count = ring.count
                let incoming = ring[index] - ring[(index + count - 1) % count], outgoing = ring[(index + 1) % count] - ring[index]
                let lengths = Double(simd_length(incoming)) * Double(simd_length(outgoing))
                let dot = Double(incoming.x) * Double(outgoing.x) + Double(incoming.y) * Double(outgoing.y)
                if lengths > 0, dot > 0, abs(cross(incoming, outgoing)) <= collinearTolerance * lengths {
                    ring.remove(at: index)
                    removed = true
                } else {
                    index += 1
                }
            }
        }
        return ring
    }
}
