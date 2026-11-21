import Metal
import simd
import XCTest
@testable import BubblePhysicsNativeMetal

/// Budowa kontaktów z krawędziami wielokąta według obszarów (wycinek 3, P-B-24; G2-AC7): środek bańki r 24 rozmieszczony gęsto poza
/// wielokątem wokół wierzchołków 30°, 90°, 120° i 270°, także dokładnie na granicach obszarów i o jedno ULP obok, ma co najmniej
/// jeden kontakt z krawędzią i nigdy dwóch o normalnych różniących się o mniej niż 1e-3 rad. Odcinki pochodzą z
/// `NativeStaticPolygonEdges`, a solver dostaje jedną bańkę na klatkę (bańki nie mogą się wzajemnie przesuwać).
@MainActor
final class NativeStaticPolygonContactTests: XCTestCase {
    private typealias Point = SIMD2<Float>
    private let radius: Float = 24

    private struct Corner {
        var name: String
        var polygon: [Point]
        var vertex: Point
    }

    /// Trójkąt równoramienny o wierzchołku w (0, 0), kącie `degrees` i ramionach 100; obieg zgodny z ruchem wskazówek zegara.
    private func apex(_ degrees: Float) -> Corner {
        let half = degrees * .pi / 360
        return Corner(name: "\(Int(degrees))°", polygon: [[0, 0], [100 * cos(half), 100 * sin(half)], [100 * cos(half), -100 * sin(half)]],
                      vertex: [0, 0])
    }

    /// Litera L (ramiona 200, grubość 48): wypukły narożnik 90° w (0, 0) i wklęsły 270° w (48, 48).
    private var corners: [Corner] {
        let letterL: [Point] = [[0, 0], [200, 0], [200, 48], [48, 48], [48, 200], [0, 200]]
        return [apex(30), Corner(name: "90°", polygon: letterL, vertex: [0, 0]), apex(120),
                Corner(name: "270°", polygon: letterL, vertex: [48, 48])]
    }

    private func contains(_ polygon: [Point], _ p: Point) -> Bool {
        var inside = false
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) { inside.toggle() }
        }
        return inside
    }

    private func distance(_ p: Point, toSegment a: Point, _ b: Point) -> Float {
        let edge = b - a, along = simd_dot(p - a, edge) / max(simd_dot(edge, edge), .leastNormalMagnitude)
        return simd_distance(p, a + min(max(along, 0), 1) * edge)
    }

    private func distance(_ p: Point, to polygon: [Point]) -> Float {
        polygon.indices.map { distance(p, toSegment: polygon[$0], polygon[($0 + 1) % polygon.count]) }.min() ?? .infinity
    }

    /// Środki wokół wierzchołka: przegląd kątów co 5°, kąty graniczne (prostopadłe do obu sąsiednich krawędzi) i punkty o jedno ULP obok nich.
    private func centers(_ corner: Corner, ring: [Point]) -> [Point] {
        let index = ring.firstIndex(of: corner.vertex)!
        let previous = ring[(index + ring.count - 1) % ring.count], next = ring[(index + 1) % ring.count]
        func unit(_ v: Point) -> Point { v / simd_length(v) }
        let incoming = unit(corner.vertex - previous), outgoing = unit(next - corner.vertex)
        var angles = stride(from: Float(0), to: 360, by: 5).map { $0 * .pi / 180 }
        // Promienie graniczne obszarów: prostopadłe do krawędzi w wierzchołku, po obu stronach.
        for direction in [incoming, outgoing] {
            let normal = Point(-direction.y, direction.x)
            angles.append(atan2(normal.y, normal.x)); angles.append(atan2(-normal.y, -normal.x))
        }
        var result: [Point] = []
        for angle in angles {
            for scale: Float in [0.5, 0.95] {
                let p = corner.vertex + scale * radius * Point(cos(angle), sin(angle))
                result.append(p)
                // Jedno ULP obok w każdej współrzędnej.
                for variant in [Point(p.x.nextUp, p.y), Point(p.x.nextDown, p.y), Point(p.x, p.y.nextUp), Point(p.x, p.y.nextDown)] {
                    result.append(variant)
                }
            }
        }
        result += boundaryCenters(corner, incoming: incoming, outgoing: outgoing)
        return result.filter { !contains(ring, $0) && distance($0, to: ring) > 1e-3 && distance($0, to: ring) < radius }
    }

    /// Środki dokładnie na granicach obszarów i w oknie ±8 ULP wokół nich: dla każdej z dwóch prostych prostopadłych do krawędzi w
    /// wierzchołku (`dot(środek − wierzchołek, kierunek) = 0`) przesuwamy jedną współrzędną po kolejnych liczbach Float wokół rozwiązania
    /// tego równania, dla kilku odległości po obu stronach. Dla krawędzi osiowych (wierzchołki 90° i 270°) rozwiązanie wypada dokładnie
    /// w zerze, więc okno zawiera `along == 0` (także dla -0.0); dla ukośnych okno obejmuje zmianę znaku predykatu jądra.
    private func boundaryCenters(_ corner: Corner, incoming: Point, outgoing: Point) -> [Point] {
        var result: [Point] = []
        let vertex = corner.vertex
        for direction in [incoming, outgoing] {
            let normal = Point(-direction.y, direction.x)
            for sign: Float in [1, -1] {
                for distance: Float in [0.5 * radius, 0.95 * radius] {
                    let seed = vertex + sign * distance * normal
                    // Rozwiązujemy po tej współrzędnej, która jest dobrze uwarunkowana, i przesuwamy ją po sąsiednich Float.
                    let solveX = abs(direction.x) >= abs(direction.y)
                    var exact = seed
                    if solveX { exact.x = vertex.x - (seed.y - vertex.y) * direction.y / direction.x } else { exact.y = vertex.y - (seed.x - vertex.x) * direction.x / direction.y }
                    var below = solveX ? exact.x : exact.y, above = below
                    var window = [below]
                    for _ in 0..<8 { below = below.nextDown; above = above.nextUp; window.append(below); window.append(above) }
                    if (solveX ? exact.x : exact.y) == 0 { window.append(-0.0) }
                    for value in window { result.append(solveX ? Point(value, exact.y) : Point(exact.x, value)) }
                }
            }
        }
        return result
    }

    func testEveryCenterCloserThanTheRadiusHasOneNonDuplicatedContactAroundEveryVertex() async throws {
        let solver = try NativeMetalSolver(device: XCTUnwrap(MTLCreateSystemDefaultDevice()))
        var step = 0
        var checked = 0
        for corner in corners {
            for reversed in [false, true] {
                let ring = reversed ? Array(corner.polygon.reversed()) : corner.polygon
                let segments = NativeStaticPolygonEdges.segments(points: ring, firstID: 1, ownerID: 5)
                for center in centers(corner, ring: ring) {
                    step += 1
                    // Świeże ID bańki w każdej klatce: bez historii cache, a stare rekordy odfiltrowuje `lastSeenFrame`.
                    let bubble = NativeSolverBubble(id: .init(rawValue: 1_000 + step), center: center, mass: 1, targetRadius: radius)
                    let input = NativeSolverInput(configuration: .init(timeStep: 1 / 60, linearDamping: 0, angularDamping: 0),
                                                  bubbles: [bubble], segments: segments)
                    let frame = try await solver.executeFrame(input: input, scenarioStep: step)
                    let normals = frame.contacts.filter { $0.kind == .bubbleSegment }.map(\.normal)
                    let name = "\(corner.name), odwrócony \(reversed), środek \(center)"
                    XCTAssertGreaterThanOrEqual(normals.count, 1, "\(name): brak kontaktu")
                    for first in normals.indices {
                        for second in normals.indices where second > first {
                            let angle = abs(atan2(normals[first].x * normals[second].y - normals[first].y * normals[second].x,
                                                  simd_dot(normals[first], normals[second])))
                            XCTAssertGreaterThanOrEqual(angle, 1e-3, "\(name): dwa kontakty o prawie tej samej normalnej \(normals[first]), \(normals[second])")
                        }
                    }
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 500)
    }
}
