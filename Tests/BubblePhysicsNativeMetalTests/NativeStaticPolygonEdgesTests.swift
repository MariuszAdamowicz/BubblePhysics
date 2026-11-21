import simd
import XCTest
@testable import BubblePhysicsNativeMetal

/// Budowa jednostronnych krawędzi statycznego wielokąta (wycinek 3, P-B-30): strona zewnętrzna ze znaku pola, wypukłość końców,
/// sąsiad przy wierzchołku początkowym i scalanie krawędzi współliniowych w tolerancji 1e-5.
final class NativeStaticPolygonEdgesTests: XCTestCase {
    private typealias Point = SIMD2<Float>

    /// Litera L o ramionach 200 i grubości 48, obieg przeciwny do ruchu wskazówek zegara; wierzchołek (48, 48) jest wklęsły.
    private let letterL: [Point] = [[0, 0], [200, 0], [200, 48], [48, 48], [48, 200], [0, 200]]
    private let square: [Point] = [[0, 0], [100, 0], [100, 100], [0, 100]]
    /// Trójkąt równoramienny z kątem 30° przy (0, 0) i ramionami 100; obieg zgodny z ruchem wskazówek zegara.
    private let triangle: [Point] = [[0, 0], [100 * cos(Float.pi / 12), 100 * sin(Float.pi / 12)], [100 * cos(Float.pi / 12), -100 * sin(Float.pi / 12)]]

    private func segments(_ points: [Point]) -> [NativeSolverSegment] {
        NativeStaticPolygonEdges.segments(points: points, firstID: 10, ownerID: 77)
    }

    /// Czy punkt leży wewnątrz wielokąta (parzystość przecięć).
    private func contains(_ polygon: [Point], _ p: Point) -> Bool {
        var inside = false
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            if (a.y > p.y) != (b.y > p.y), p.x < a.x + (p.y - a.y) / (b.y - a.y) * (b.x - a.x) { inside.toggle() }
        }
        return inside
    }

    func testSegmentsKeepGeometryIdentifiersAndOwner() throws {
        let result = segments(square)
        XCTAssertEqual(result.map(\.id), [10, 11, 12, 13])
        XCTAssertTrue(result.allSatisfy { $0.ownerID == 77 && !$0.isKinematic && $0.allowedSide == nil })
        for (index, segment) in result.enumerated() {
            XCTAssertEqual(segment.currentA, square[index])
            XCTAssertEqual(segment.currentB, square[(index + 1) % square.count])
            XCTAssertEqual(segment.previousA, segment.currentA)
            XCTAssertEqual(segment.previousB, segment.currentB)
            XCTAssertNotNil(segment.polygonEdge)
        }
    }

    func testOutwardSideFollowsTheWindingForEveryEdge() throws {
        for (name, polygon) in [("kwadrat", square), ("L", letterL), ("trójkąt", triangle)] {
            for reversed in [false, true] {
                let ring = reversed ? Array(polygon.reversed()) : polygon
                for segment in segments(ring) {
                    let edge = try XCTUnwrap(segment.polygonEdge)
                    let direction = segment.currentB - segment.currentA
                    let left = Point(-direction.y, direction.x) / simd_length(direction)
                    XCTAssertEqual(abs(edge.outwardSign), 1, "\(name)")
                    let middle = (segment.currentA + segment.currentB) / 2
                    XCTAssertFalse(contains(ring, middle + left * edge.outwardSign * 0.01),
                                   "\(name), odwrócony \(reversed), odcinek \(segment.id): punkt po stronie zewnętrznej leży wewnątrz")
                    XCTAssertTrue(contains(ring, middle - left * edge.outwardSign * 0.01),
                                  "\(name), odwrócony \(reversed), odcinek \(segment.id): punkt po stronie wewnętrznej leży na zewnątrz")
                }
            }
        }
    }

    func testEndConvexityMatchesTheGeometryForBothWindings() throws {
        for reversed in [false, true] {
            let ring = reversed ? Array(letterL.reversed()) : letterL
            for (index, segment) in segments(ring).enumerated() {
                let edge = try XCTUnwrap(segment.polygonEdge)
                let startIsInnerCorner = segment.currentA == Point(48, 48), endIsInnerCorner = segment.currentB == Point(48, 48)
                XCTAssertEqual(edge.convexStart, !startIsInnerCorner, "L, odwrócony \(reversed), początek odcinka \(index)")
                XCTAssertEqual(edge.convexEnd, !endIsInnerCorner, "L, odwrócony \(reversed), koniec odcinka \(index)")
            }
        }
        for segment in segments(triangle) {
            let edge = try XCTUnwrap(segment.polygonEdge)
            XCTAssertTrue(edge.convexStart && edge.convexEnd, "każdy wierzchołek trójkąta jest wypukły")
        }
    }

    func testPreviousStartIsTheStartOfThePreviousEdgeCyclically() throws {
        for reversed in [false, true] {
            let result = segments(reversed ? Array(letterL.reversed()) : letterL)
            for (index, segment) in result.enumerated() {
                let edge = try XCTUnwrap(segment.polygonEdge)
                XCTAssertEqual(edge.previousStart, result[(index + result.count - 1) % result.count].currentA,
                               "L, odwrócony \(reversed), odcinek \(index)")
            }
        }
    }

    func testNearlyCollinearEdgesInsideTheToleranceAreMerged() throws {
        // Wierzchołek (400, 1,8e-3) między (0, 0) a (800, 0): |cross| / (|e1| |e2|) ≈ 0,9e-5, tuż pod tolerancją 1e-5.
        let wall: [Point] = [[0, 0], [400, 1.8e-3], [800, 0], [800, 48], [0, 48]]
        let merged = segments(wall)
        XCTAssertEqual(merged.count, 4, "krawędzie w tolerancji 1e-5 mają się scalić")
        let long = try XCTUnwrap(merged.first { $0.currentA == Point(0, 0) })
        XCTAssertEqual(long.currentB, Point(800, 0), "scalona krawędź idzie od pierwszego do ostatniego wierzchołka")
        XCTAssertEqual(merged.map(\.id), [10, 11, 12, 13], "identyfikatory idą bez luk po scaleniu")
        for segment in merged {
            let edge = try XCTUnwrap(segment.polygonEdge)
            XCTAssertTrue(edge.convexStart && edge.convexEnd, "po scaleniu każdy wierzchołek jest ściśle wypukły")
        }
    }

    func testEdgesJustOutsideTheToleranceAreNotMerged() throws {
        // |cross| / (|e1| |e2|) ≈ bend / 200 dla wierzchołka (400, bend) między (0, 0) a (800, 0): 1,1e-5 przy bend = 2,2e-3.
        func wall(bend: Float) -> [Point] { [[0, 0], [400, bend], [800, 0], [800, 48], [0, 48]] }
        XCTAssertEqual(segments(wall(bend: 2.2e-3)).count, 5, "tuż nad tolerancją 1e-5 (1,1e-5) krawędzie zostają")
        XCTAssertEqual(segments(wall(bend: 50)).count, 5)
        XCTAssertEqual(segments(wall(bend: -50)).count, 5, "wierzchołek wklęsły też zostaje")
        XCTAssertEqual(segments(wall(bend: 1.8e-3)).count, 4, "tuż pod tolerancją (0,9e-5) się scala")
    }

    func testExactlyCollinearVertexIsRemovedForBothWindings() throws {
        let doubled: [Point] = [[0, 0], [100, 0], [200, 0], [200, 100], [0, 100]]
        for ring in [doubled, Array(doubled.reversed())] {
            let result = segments(ring)
            XCTAssertEqual(result.count, 4)
            XCTAssertTrue(result.contains { Set([$0.currentA, $0.currentB]) == Set([Point(0, 0), Point(200, 0)]) })
        }
    }
}
